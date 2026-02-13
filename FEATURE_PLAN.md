# OpenTrace Ruby Gem — Feature Roadmap

> 15 features derived from competitive analysis of Sentry, Datadog, AppSignal, Logtail, PaperTrail, and Logstash-logger.
> Each feature includes: what it is, why it matters, performance impact, implementation details, files touched, and a concrete example of how Claude Code would implement it.

---

## Performance Guarantee

**Core invariant: zero measurable impact on the host Rails app.**

Every feature in this plan is designed so that the request thread — the code path that determines user-facing latency — does the absolute minimum work. All heavy lifting (hash building, timestamp formatting, JSON serialization, regex scrubbing, EXPLAIN queries) runs on background threads.

### Total Request-Thread Overhead (All 15 Features Enabled)

| Scenario | Added Latency | Where the Time Goes |
|----------|--------------|---------------------|
| Normal request (no errors, no custom spans) | **~5-10μs** | Transaction name (5ns) + session ID (20ns) + trace injection (~50ns/log line) + query fingerprints (~100ns/query) |
| Request with 5 custom spans + 5 breadcrumbs | **~12-15μs** | Above + span start/finish (200ns each) + breadcrumb appends (100ns each) |
| Error request (with source context, cause chain) | **~1ms** | Source file read (~1ms, cached after first hit) + cause chain walk (~50ns) |
| All features OFF (default config) | **0μs** | All features default to disabled; only enabled features have any cost |

For context: a typical Rails request takes **5-50ms**. Even the worst case (15μs) is **0.03%** of a 50ms request.

### What Runs Where

| Thread | Work | Features |
|--------|------|----------|
| **Request thread** (latency-sensitive) | Fiber-local reads/writes, Array.push, clock_gettime | 1, 2, 3, 5, 6, 8, 9, 10, 11 |
| **Background dispatch thread** (async) | PayloadBuilder materialize, JSON, gzip, HTTP/socket, PII scrub, SQL normalize, EXPLAIN | 4, 7, 12, 14 |
| **Background timer thread** (periodic) | GC.stat, RSS read | 15 |
| **User's rescue blocks only** (explicit opt-in) | binding.local_variables | 13 |

### Memory Budget

| Component | Memory | Lifecycle |
|-----------|--------|-----------|
| Breadcrumb buffer | 5KB max (25 crumbs) | Per-request, freed at end |
| Query fingerprint map | 2KB max (100 entries) | Per-request, freed at end |
| Source file cache | ~500KB (50 files) | Global, LRU-evicted |
| Runtime monitor thread | ~8KB (thread stack) | Global, one thread |
| **Total steady-state** | **~510KB** | |

### Design Principles

1. **All features default to OFF.** Users opt-in to what they need. Baseline overhead is 0μs.
2. **Never block the request thread.** EXPLAIN, PII scrubbing, SQL normalization — all background.
3. **Never use global VM hooks.** No TracePoint(:raise), no ObjectSpace, no set_trace_func. These have invisible costs on every Ruby operation.
4. **Bounded everything.** Breadcrumbs capped at 25, fingerprints at 100, cause chain at 5, source cache at 50 files. No unbounded growth.
5. **Never raise to the host app.** Every public method and subscriber wraps in `rescue StandardError`.

---

## Table of Contents

| # | Feature | Priority | Est. Files | Request-Thread Cost |
|---|---------|----------|------------|---------------------|
| 1 | [Custom Instrumentation API](#1-custom-instrumentation-api) | HIGH | 4 | ~200ns per `trace` call |
| 2 | [Exception Cause Chaining](#2-exception-cause-chaining) | HIGH | 3 | ~50ns per error (pointer walk) |
| 3 | [Breadcrumbs API](#3-breadcrumbs-api) | HIGH | 5 | ~100ns per breadcrumb |
| 4 | [SQL Query Normalization](#4-sql-query-normalization) | HIGH | 3 | **0ns** (background thread) |
| 5 | [Custom Transaction Naming](#5-custom-transaction-naming) | HIGH | 3 | ~5ns (Fiber write) |
| 6 | [Source Code Context](#6-source-code-context) | HIGH | 3 | ~1ms per error (cached File.read) |
| 7 | [Built-in PII Scrubbers](#7-built-in-pii-scrubbers) | MEDIUM | 3 | **0ns** (background thread) |
| 8 | [Automatic Log Trace Injection](#8-automatic-log-trace-injection) | MEDIUM | 3 | ~50ns per log line (0ns outside requests) |
| 9 | [Session Tracking](#9-session-tracking) | MEDIUM | 3 | ~20ns per request |
| 10 | [Duplicate Query Detection](#10-duplicate-query-detection) | MEDIUM | 3 | ~100ns per SQL query |
| 11 | [Lifecycle Callbacks](#11-lifecycle-callbacks) | MEDIUM | 4 | ~10ns per hook (nil check) |
| 12 | [Unix Socket Transport](#12-unix-socket-transport) | MEDIUM | 2 | **0ns** (background thread, saves ~0.5ms) |
| 13 | [Local Variables Capture](#13-local-variables-capture) | LOW | 2 | ~5μs per explicit `capture_binding` call |
| 14 | [EXPLAIN Plan Capture](#14-explain-plan-capture) | LOW | 3 | **0ns** (background thread + separate DB connection) |
| 15 | [GC / Runtime Metrics](#15-gc--runtime-metrics) | LOW | 3 | **0ns** (background timer thread) |

---

## 1. Custom Instrumentation API

### What
A block-based `OpenTrace.trace(name) { ... }` API that creates a timed span, captures its duration, and records it as a structured event. Inspired by Datadog's `Datadog.trace()`, Sentry's manual spans, and AppSignal's `Appsignal.instrument()`.

### Why It Matters
- Users currently have no way to time arbitrary code blocks (payment processing, external API calls, PDF generation, etc.)
- Without this, OpenTrace can only report on what Rails instruments automatically — leaving custom business logic invisible
- Every major APM competitor offers this — it's table-stakes for debugging production performance issues
- Enables users to drill into the "other" time in time_breakdown (currently a black box)

### Performance Impact
- **~200ns per `trace` call** — one `clock_gettime` at start, one at end, one Fiber read, one Array push
- **Zero cost when not called** — no global hooks, no monkey-patching
- Spans are pushed as frozen Arrays (same deferred pattern as `OpenTrace.log`), materialized on background thread
- Nested spans add ~50ns each (Fiber stack push/pop)

### Implementation

**New public API in `opentrace.rb`:**
```ruby
module OpenTrace
  class << self
    # Trace a block of code, recording its duration as a span.
    #
    #   OpenTrace.trace("stripe.charge") do
    #     Stripe::Charge.create(amount: 2000, currency: "usd")
    #   end
    #
    #   OpenTrace.trace("pdf.generate", resource: "Invoice") do |span|
    #     span.set_tag(:pages, 42)
    #     generate_invoice_pdf(order)
    #   end
    #
    def trace(operation_name, resource: nil, tags: {})
      return yield(NilSpan::INSTANCE) unless enabled?

      span = Span.new(
        operation: operation_name,
        resource: resource,
        parent_span_id: Fiber[:opentrace_span_id],
        trace_id: Fiber[:opentrace_trace_id]
      )

      # Push new span onto the Fiber-local span stack
      previous_span_id = Fiber[:opentrace_span_id]
      Fiber[:opentrace_span_id] = span.span_id

      begin
        result = yield(span)
        span.finish(tags: tags)
        result
      rescue => e
        span.finish(error: e, tags: tags)
        raise
      ensure
        Fiber[:opentrace_span_id] = previous_span_id
      end
    end
  end

  class Span
    attr_reader :span_id, :operation, :resource

    def initialize(operation:, resource:, parent_span_id:, trace_id:)
      @operation = operation
      @resource = resource
      @span_id = TraceContext.generate_span_id
      @parent_span_id = parent_span_id
      @trace_id = trace_id
      @start = Process.clock_gettime(Process::CLOCK_REALTIME)
      @tags = {}
      @finished = false
    end

    def set_tag(key, value)
      @tags[key] = value
    end

    def finish(error: nil, tags: {})
      return if @finished
      @finished = true
      duration = Process.clock_gettime(Process::CLOCK_REALTIME) - @start

      meta = @tags.merge(tags)
      meta[:span_operation] = @operation
      meta[:span_resource] = @resource if @resource
      meta[:span_duration_ms] = (duration * 1000).round(2)

      if error
        meta[:exception_class] = error.class.name
        meta[:exception_message] = error.message&.slice(0, 500)
      end

      level = error ? "ERROR" : "INFO"
      OpenTrace.log(level, "span:#{@operation}", meta)

      # Also record in RequestCollector timeline if present
      collector = Fiber[:opentrace_collector]
      collector&.record_span(operation: @operation, duration_ms: meta[:span_duration_ms])
    end
  end

  # Null object span for when OpenTrace is disabled
  class NilSpan
    INSTANCE = new.freeze
    def set_tag(_, _) = nil
    def finish(**) = nil
  end
end
```

**RequestCollector addition:**
```ruby
def record_span(operation:, duration_ms:)
  if @timeline_enabled
    append_timeline({ t: :span, n: operation, ms: duration_ms.round(1), at: offset_ms })
  end
end
```

### Files Changed

| File | Change |
|------|--------|
| `lib/opentrace.rb` | Add `trace` method, `Span` class, `NilSpan` class |
| `lib/opentrace/request_collector.rb` | Add `record_span` method |
| `spec/opentrace/span_spec.rb` | **New** — unit tests for Span lifecycle |
| `spec/opentrace/trace_api_spec.rb` | **New** — integration tests for `OpenTrace.trace` |

### Benefits
- Closes the biggest gap vs Datadog/Sentry/AppSignal
- Enables per-operation latency tracking for business logic
- Spans appear in the existing timeline — no server changes needed
- Nested spans preserve parent/child relationships via `span_id`/`parent_span_id`

### Claude Code Implementation Example
```
User: "Add tracing around the Stripe payment flow in our checkout controller"

Claude Code would:
1. Read app/controllers/checkout_controller.rb
2. Wrap the payment block:

   def create
     OpenTrace.trace("checkout.payment", resource: "Order##{@order.id}") do |span|
       span.set_tag(:amount, @order.total_cents)
       span.set_tag(:currency, @order.currency)
       charge = Stripe::Charge.create(...)
       span.set_tag(:stripe_charge_id, charge.id)
       charge
     end
   end

3. No config changes needed — works immediately
```

---

## 2. Exception Cause Chaining

### What
Walk Ruby's `exception.cause` chain and capture the full exception tree in the error payload. Currently only the top-level exception is captured, losing critical root-cause information.

### Why It Matters
- In Ruby, wrapped exceptions (e.g. `ActiveRecord::StatementInvalid` wrapping `PG::ConnectionBad`) hide the real root cause
- Developers see "StatementInvalid" in their dashboard but the actual problem is a Postgres connection timeout 3 levels deep
- Sentry captures the full cause chain — it's one of their most-used debugging features
- Without this, users must reproduce errors locally to find root causes

### Performance Impact
- **~50ns per error** — walks 1-3 pointers (`.cause` chain), captures class name + message only
- **Zero cost on non-error paths** — only triggered inside `OpenTrace.error` and exception payloads
- Chain depth capped at 5 to prevent pathological cases
- No additional allocations beyond the metadata hash entries

### Implementation

**Changes to `opentrace.rb` `error` method:**
```ruby
def error(exception, metadata = {})
  return unless enabled?

  meta = metadata.is_a?(Hash) ? metadata.dup : {}
  meta[:exception_class]   = exception.class.name
  meta[:exception_message] = exception.message&.slice(0, 500)

  if exception.backtrace
    cleaned = clean_backtrace_for(exception)
    meta[:backtrace] = cleaned.first(15)
    meta[:error_fingerprint] = compute_error_fingerprint(exception.class.name, cleaned)
  end

  # NEW: Capture exception cause chain (max 5 deep)
  if exception.cause
    meta[:exception_causes] = build_cause_chain(exception.cause, depth: 0)
  end

  log("ERROR", exception.message.to_s, meta)
rescue StandardError
end

private

MAX_CAUSE_DEPTH = 5

def build_cause_chain(exception, depth:)
  return nil if exception.nil? || depth >= MAX_CAUSE_DEPTH

  cause_entry = {
    class: exception.class.name,
    message: exception.message&.slice(0, 300)
  }

  if exception.backtrace
    cleaned = clean_backtrace_for(exception)
    cause_entry[:backtrace] = cleaned.first(5) # Shorter backtrace for causes
    cause_entry[:origin] = cleaned.first
  end

  chain = [cause_entry]
  if exception.cause
    chain.concat(build_cause_chain(exception.cause, depth: depth + 1) || [])
  end
  chain
end

def clean_backtrace_for(exception)
  if defined?(::Rails) && ::Rails.respond_to?(:backtrace_cleaner)
    ::Rails.backtrace_cleaner.clean(exception.backtrace)
  else
    exception.backtrace.reject { |l| l.include?("/gems/") }
  end
end
```

**PayloadBuilder changes for `:request` entries:**
```ruby
# In materialize_request, after the exc_backtrace block:
if exc_backtrace
  # ... existing backtrace code ...

  # Walk the cause chain from the original exception object
  # (We need to pass the exception object through the deferred array)
end
```

Note: The `:request` deferred array format needs a new slot for `exception_object` (or we serialize the cause chain eagerly since it's only on error paths and errors are rare).

### Files Changed

| File | Change |
|------|--------|
| `lib/opentrace.rb` | Add `build_cause_chain`, modify `error` method |
| `lib/opentrace/payload_builder.rb` | Handle `exception_causes` in request materialization |
| `spec/opentrace/exception_chain_spec.rb` | **New** — tests for cause chain capture |

### Benefits
- Root-cause visibility without reproducing errors locally
- Matches Sentry's error analysis capability
- Dramatically reduces debugging time for wrapped exceptions (ActiveRecord, ActionView, Faraday)
- Server receives `metadata.exception_causes` as a JSON array — no schema changes needed (stored in metadata)

### Claude Code Implementation Example
```
User: "I keep seeing ActiveRecord::StatementInvalid errors but I can't figure out why"

Claude Code would:
1. Read the OpenTrace dashboard (or logs) and see:
   - exception_class: "ActiveRecord::StatementInvalid"
   - exception_causes: [
       { class: "PG::ConnectionBad", message: "connection timed out", origin: "app/models/user.rb:42" }
     ]
2. Immediately identify: "Your Postgres connections are timing out in User#find_by_email.
   Check your connection pool size and PgBouncer timeout settings."
3. No code changes needed — the cause chain is captured automatically
```

---

## 3. Breadcrumbs API

### What
A manual breadcrumb trail API: `OpenTrace.add_breadcrumb(category, message, data)`. Breadcrumbs are lightweight, timestamped events that accumulate per-request and get attached to the next error. Distinct from the timeline (which records framework events), breadcrumbs capture user/developer-defined checkpoints.

### Why It Matters
- When an error occurs, you often need to know "what happened before the crash" — not just framework events, but business logic checkpoints
- Sentry's breadcrumbs are one of their most valuable features for debugging: "user clicked checkout → validated cart → applied coupon → started payment → CRASH"
- The existing timeline captures SQL/view/cache, but can't capture business logic steps
- Breadcrumbs are lighter than log entries (not sent individually, only attached to errors)

### Performance Impact
- **~100ns per breadcrumb** — append to Fiber-local array (no thread sync, no queue push)
- **Zero network cost for successful requests** — breadcrumbs only travel with error payloads
- **Capped at 25 breadcrumbs per request** (FIFO ring buffer) — bounded memory
- **Zero cost when not called** — no monkey-patching, no subscribers

### Implementation

**New `breadcrumbs.rb`:**
```ruby
# frozen_string_literal: true

module OpenTrace
  class Breadcrumb
    attr_reader :category, :message, :data, :timestamp, :level

    def initialize(category:, message:, data: nil, level: "info")
      @category = category.to_s
      @message = message.to_s
      @data = data
      @level = level.to_s
      @timestamp = Process.clock_gettime(Process::CLOCK_REALTIME)
    end

    def to_h
      h = { category: @category, message: @message, level: @level, timestamp: @timestamp }
      h[:data] = @data if @data
      h
    end
  end

  class BreadcrumbBuffer
    MAX_BREADCRUMBS = 25

    def initialize
      @buffer = []
    end

    def add(breadcrumb)
      @buffer.shift if @buffer.size >= MAX_BREADCRUMBS
      @buffer << breadcrumb
    end

    def to_a
      @buffer.map(&:to_h)
    end

    def empty?
      @buffer.empty?
    end

    def size
      @buffer.size
    end
  end
end
```

**New public API in `opentrace.rb`:**
```ruby
module OpenTrace
  class << self
    # Add a breadcrumb to the current request's trail.
    # Breadcrumbs are attached to error payloads for debugging.
    #
    #   OpenTrace.add_breadcrumb("auth", "User logged in", { user_id: 42 })
    #   OpenTrace.add_breadcrumb("cart", "Item added", { sku: "ABC-123" })
    #   OpenTrace.add_breadcrumb("payment", "Charge initiated", { amount: 2000 })
    #
    def add_breadcrumb(category, message, data = nil, level: "info")
      return unless enabled?
      buffer = Fiber[:opentrace_breadcrumbs] ||= BreadcrumbBuffer.new
      crumb = Breadcrumb.new(category: category, message: message, data: data, level: level)

      if config.before_breadcrumb
        crumb = config.before_breadcrumb.call(crumb) rescue crumb
        return unless crumb
      end

      buffer.add(crumb)
    rescue StandardError
      # Never raise
    end

    # Get the current request's breadcrumbs (for testing/debugging)
    def current_breadcrumbs
      Fiber[:opentrace_breadcrumbs]&.to_a || []
    end
  end
end
```

**Middleware cleanup in `middleware.rb`:**
```ruby
ensure
  # ... existing cleanup ...
  Fiber[:opentrace_breadcrumbs] = nil
```

**Attach breadcrumbs to error payloads in `payload_builder.rb`:**
```ruby
# In materialize_request, when exc_class is present:
breadcrumbs = entry[18] # new slot in :request array
if breadcrumbs && !breadcrumbs.empty?
  meta[:breadcrumbs] = breadcrumbs
end

# In materialize_log, when level is ERROR:
if level.to_s.upcase == "ERROR"
  # breadcrumbs are passed as last element of the deferred array
  crumbs = entry[11]
  meta[:breadcrumbs] = crumbs if crumbs && !crumbs.empty?
end
```

**Modified `error` method to capture breadcrumbs:**
```ruby
def error(exception, metadata = {})
  # ... existing code ...

  # Capture current breadcrumbs for this error
  buffer = Fiber[:opentrace_breadcrumbs]
  if buffer && !buffer.empty?
    meta[:breadcrumbs] = buffer.to_a
  end

  log("ERROR", exception.message.to_s, meta)
end
```

### Config Addition
```ruby
attr_accessor :before_breadcrumb  # Proc(Breadcrumb) -> Breadcrumb|nil
```

### Files Changed

| File | Change |
|------|--------|
| `lib/opentrace/breadcrumbs.rb` | **New** — Breadcrumb, BreadcrumbBuffer classes |
| `lib/opentrace.rb` | Add `add_breadcrumb`, `current_breadcrumbs`, capture in `error` |
| `lib/opentrace/config.rb` | Add `before_breadcrumb` attribute |
| `lib/opentrace/middleware.rb` | Clear `Fiber[:opentrace_breadcrumbs]` in ensure |
| `spec/opentrace/breadcrumbs_spec.rb` | **New** — full breadcrumb lifecycle tests |

### Benefits
- Gives context to errors beyond just stack traces
- Breadcrumbs travel with errors only — zero network overhead for successful requests
- The FIFO buffer prevents unbounded memory growth
- `before_breadcrumb` hook lets users scrub sensitive data
- Server needs no changes — breadcrumbs arrive as `metadata.breadcrumbs` JSON array

### Claude Code Implementation Example
```
User: "Help me debug why checkout is failing for some users"

Claude Code would:
1. Add breadcrumbs at key business logic points:

   def checkout
     OpenTrace.add_breadcrumb("checkout", "Started", { cart_items: @cart.items.count })

     OpenTrace.add_breadcrumb("checkout", "Validating address", { country: @address.country })
     validate_address!

     OpenTrace.add_breadcrumb("checkout", "Applying discount", { code: @coupon&.code })
     apply_discount! if @coupon

     OpenTrace.add_breadcrumb("payment", "Charging card", { amount: @total, gateway: "stripe" })
     charge_card!
   end

2. When errors occur, the breadcrumb trail shows exactly
   which step failed and what state the checkout was in.
```

---

## 4. SQL Query Normalization

### What
Replace literal values in SQL queries with `?` placeholders before storing, so `SELECT * FROM users WHERE id = 42 AND email = 'alice@example.com'` becomes `SELECT * FROM users WHERE id = ? AND email = ?`. This enables query grouping, pattern detection, and prevents PII leakage.

### Why It Matters
- Without normalization, every query is unique — impossible to group "the same query with different params"
- The server can't compute "this query pattern runs 10,000 times/day" or "this pattern got 50% slower since last deploy"
- SQL literals may contain PII (emails, names, addresses) that shouldn't be stored
- Datadog does this automatically and it's fundamental to their APM query analysis

### Performance Impact
- **~500ns per SQL query** — single-pass regex replacement
- **Only runs on the background thread** (in PayloadBuilder) — zero impact on request thread
- **Only runs when `sql_logging: true`** — zero cost for most users
- The normalized form is shorter, reducing payload size

### Implementation

**New `sql_normalizer.rb`:**
```ruby
# frozen_string_literal: true

module OpenTrace
  module SqlNormalizer
    module_function

    # Replace literal values with ? placeholders for grouping.
    # Handles: integers, floats, single-quoted strings, double-quoted strings,
    # IN (...) lists, boolean literals, NULL, hex literals, timestamps.
    #
    #   normalize("SELECT * FROM users WHERE id = 42 AND name = 'Alice'")
    #   # => "SELECT * FROM users WHERE id = ? AND name = ?"
    #
    #   normalize("INSERT INTO logs (msg) VALUES ('hello'), ('world')")
    #   # => "INSERT INTO logs (msg) VALUES (?), (?)"
    #
    def normalize(sql)
      return sql if sql.nil? || sql.empty?

      sql.gsub(LITERAL_PATTERN, "?")
    end

    # Compute a fingerprint for a normalized query.
    # Two queries with the same fingerprint are "the same query with different params."
    def fingerprint(sql)
      normalized = normalize(sql)
      Digest::MD5.hexdigest(normalized)[0, 12]
    end

    private_constant :LITERAL_PATTERN

    # Order matters: strings first (to avoid matching numbers inside strings),
    # then numbers, then special literals.
    LITERAL_PATTERN = Regexp.union(
      /'(?:[^'\\]|\\.)*'/,           # single-quoted strings
      /"(?:[^"\\]|\\.)*"/,           # double-quoted strings (MySQL)
      /\b0x[0-9a-fA-F]+\b/,         # hex literals
      /\b\d+\.\d+\b/,               # floats
      /\b\d+\b/,                     # integers
      /\bTRUE\b/i,                   # boolean TRUE
      /\bFALSE\b/i,                  # boolean FALSE
      /\bNULL\b/i                    # NULL
    ).freeze
  end
end
```

**Integration into PayloadBuilder (`payload_builder.rb`):**
```ruby
# In materialize_log, when the entry has SQL metadata:
def materialize_log(entry, config)
  # ... existing code ...

  # Normalize SQL if present in metadata
  if meta[:sql].is_a?(String) && config.sql_normalization
    meta[:sql_normalized] = SqlNormalizer.normalize(meta[:sql])
    meta[:sql_fingerprint] = SqlNormalizer.fingerprint(meta[:sql])
  end

  # ... rest of method ...
end
```

**Integration into Railtie SQL forwarding (`rails.rb`):**
```ruby
# In forward_sql_log, add normalized form:
if OpenTrace.config.sql_normalization
  metadata[:sql_normalized] = SqlNormalizer.normalize(payload[:sql])
  metadata[:sql_fingerprint] = SqlNormalizer.fingerprint(payload[:sql])
end
```

### Config Addition
```ruby
attr_accessor :sql_normalization  # Boolean, default: true (when sql_logging is on)
```

### Files Changed

| File | Change |
|------|--------|
| `lib/opentrace/sql_normalizer.rb` | **New** — normalization + fingerprinting |
| `lib/opentrace/config.rb` | Add `sql_normalization` attribute (default: true) |
| `lib/opentrace/rails.rb` | Attach normalized SQL + fingerprint in `forward_sql_log` |
| `spec/opentrace/sql_normalizer_spec.rb` | **New** — comprehensive normalization tests |

### Benefits
- Enables server-side query grouping and pattern analysis
- Prevents PII leakage through SQL literals
- Reduces payload size (normalized forms are shorter)
- Fingerprints enable "this query pattern" dashboards on the Go server
- Follows Datadog's approach — proven at massive scale

### Claude Code Implementation Example
```
User: "Why is our database slow?"

Claude Code would:
1. Look at OpenTrace data grouped by sql_fingerprint
2. See that fingerprint "a3f2b1c4d5e6" (normalized: "SELECT * FROM orders WHERE user_id = ? ORDER BY created_at DESC LIMIT ?")
   accounts for 45% of all SQL time
3. Recommend: "Add a composite index on orders(user_id, created_at) —
   this query pattern runs 3,200 times per hour and averages 12ms each."
```

---

## 5. Custom Transaction Naming

### What
Allow users to override the auto-detected `controller#action` transaction name with a custom string via `OpenTrace.set_transaction_name("checkout.complete")`. Essential for Grape APIs, Sinatra, custom routing, and grouping related endpoints.

### Why It Matters
- Auto-detected names like `Api::V2::OrdersController#create` are too granular — you may want all order operations grouped as "orders"
- Non-Rails frameworks (Grape, Sinatra, Hanami) don't have `controller#action` — they need manual naming
- API versioning creates duplicate entries (`V1::Users#show` vs `V2::Users#show`) that should be grouped
- Sentry and Datadog both offer this as a core feature for meaningful performance dashboards

### Performance Impact
- **~5ns per request** — single Fiber-local read in PayloadBuilder
- **Zero cost when not called** — `Fiber[:opentrace_transaction_name]` is nil, which is already checked
- No additional memory — stores a single string reference

### Implementation

**New public API in `opentrace.rb`:**
```ruby
module OpenTrace
  class << self
    # Override the auto-detected transaction name for the current request.
    #
    #   OpenTrace.set_transaction_name("checkout.complete")
    #   OpenTrace.set_transaction_name("api.orders.create")
    #
    def set_transaction_name(name)
      Fiber[:opentrace_transaction_name] = name.to_s
    end

    def current_transaction_name
      Fiber[:opentrace_transaction_name]
    end
  end
end
```

**Middleware cleanup:**
```ruby
ensure
  # ... existing cleanup ...
  Fiber[:opentrace_transaction_name] = nil
```

**PayloadBuilder uses it (if set):**
```ruby
# In materialize_request:
transaction_name = entry[19] # new slot, or read from Fiber-local captured in the array
message = if transaction_name
             "#{transaction_name} #{status} #{duration_ms.round(1)}ms"
           else
             "#{method} #{path} #{status} #{duration_ms.round(1)}ms"
           end
meta[:transaction_name] = transaction_name if transaction_name
```

**Capture in rails.rb `forward_request_log`:**
```ruby
# Add to the :request frozen array:
Fiber[:opentrace_transaction_name]  # new slot at position [18] or in extra
```

### Files Changed

| File | Change |
|------|--------|
| `lib/opentrace.rb` | Add `set_transaction_name`, `current_transaction_name` |
| `lib/opentrace/middleware.rb` | Clear `Fiber[:opentrace_transaction_name]` |
| `lib/opentrace/rails.rb` | Capture transaction name in `:request` array |
| `lib/opentrace/payload_builder.rb` | Use custom name in message + metadata |
| `spec/opentrace/transaction_naming_spec.rb` | **New** — naming override tests |

### Benefits
- Groups related endpoints into meaningful transaction categories
- Works with any Ruby framework (Grape, Sinatra, Hanami, etc.)
- Stored in `metadata.transaction_name` — server can group by this field without schema changes
- Zero overhead when not used

### Claude Code Implementation Example
```
User: "Our Grape API endpoints all show as unnamed in OpenTrace"

Claude Code would:
1. Read the Grape API routes
2. Add a before filter:

   class API < Grape::API
     before do
       route_name = "#{request.request_method} #{route.path}"
       OpenTrace.set_transaction_name(route_name)
     end
   end

3. Now all Grape endpoints show meaningful names in the dashboard
```

---

## 6. Source Code Context

### What
When an error occurs, capture 3-5 lines of source code surrounding the error's origin frame. Instead of just seeing `app/models/user.rb:42:in 'authenticate'`, the developer sees the actual code at line 42 with surrounding context.

### Why It Matters
- Backtrace lines are often not enough — you need to SEE the code to understand the error
- Sentry's source code context is one of their highest-valued features in user surveys
- Eliminates the "let me go find that file and line" step when triaging errors
- Particularly valuable when the error is in a deployed version that doesn't match the developer's local code

### Performance Impact
- **~1ms on first error per file** — `File.readlines` for one file, only on error paths
- **~5ns on subsequent errors** — served from LRU cache (max 50 files, ~500KB)
- **Zero cost on non-error paths** — only triggered when exceptions have backtraces
- **Capped**: reads only the first app-origin frame (not all 15 backtrace lines)
- **File size guard**: skips files >100KB to prevent memory spikes from generated/minified files
- **Cached per-file in production**: uses `@source_cache` (LRU, max 50 files) so repeated errors don't re-read

### Implementation

**New `source_context.rb`:**
```ruby
# frozen_string_literal: true

module OpenTrace
  module SourceContext
    CONTEXT_LINES = 3  # lines before and after the error line
    MAX_CACHE_SIZE = 50

    @cache = {}
    @mutex = Mutex.new

    module_function

    # Extract source code context around a backtrace line.
    # Returns nil if the file can't be read.
    #
    #   extract("app/models/user.rb:42:in 'authenticate'")
    #   # => {
    #   #   file: "app/models/user.rb",
    #   #   line: 42,
    #   #   method: "authenticate",
    #   #   context: {
    #   #     39 => "  def authenticate(password)",
    #   #     40 => "    return false unless password",
    #   #     41 => "    digest = BCrypt::Password.new(password_digest)",
    #   #     42 => "    digest == password  # <-- ERROR HERE",
    #   #     43 => "  rescue BCrypt::Errors::InvalidHash",
    #   #     44 => "    false",
    #   #     45 => "  end"
    #   #   }
    #   # }
    def extract(backtrace_line)
      match = backtrace_line&.match(/\A(.+):(\d+)/)
      return nil unless match

      file = match[1]
      line_no = match[2].to_i
      return nil if line_no <= 0

      # Resolve relative paths against Rails.root if available
      full_path = resolve_path(file)
      return nil unless full_path && File.exist?(full_path)
      return nil unless safe_path?(full_path)

      lines = read_file_lines(full_path)
      return nil unless lines

      start_line = [line_no - CONTEXT_LINES, 1].max
      end_line = [line_no + CONTEXT_LINES, lines.size].min

      context = {}
      (start_line..end_line).each do |n|
        context[n] = lines[n - 1]&.rstrip&.slice(0, 200)  # cap line length
      end

      {
        file: file,
        line: line_no,
        context: context
      }
    rescue StandardError
      nil
    end

    def resolve_path(file)
      if file.start_with?("/")
        file
      elsif defined?(::Rails) && ::Rails.respond_to?(:root)
        File.join(::Rails.root.to_s, file)
      else
        File.expand_path(file)
      end
    end

    MAX_FILE_SIZE = 100_000 # 100KB — skip generated/minified files

    def safe_path?(path)
      # Only read app/lib source files — never read secrets, env, etc.
      return false unless path.include?("/app/") || path.include?("/lib/") || path.include?("/config/")
      # Skip oversized files (generated code, minified assets)
      File.size(path) <= MAX_FILE_SIZE
    rescue StandardError
      false
    end

    def read_file_lines(path)
      @mutex.synchronize do
        return @cache[path] if @cache.key?(path)

        if @cache.size >= MAX_CACHE_SIZE
          @cache.delete(@cache.keys.first) # LRU eviction (approximate)
        end

        lines = File.readlines(path)
        @cache[path] = lines
        lines
      end
    rescue StandardError
      nil
    end
  end
end
```

**Integration into `opentrace.rb` `error` method:**
```ruby
def error(exception, metadata = {})
  # ... existing code ...

  if exception.backtrace && config.source_context
    cleaned = clean_backtrace_for(exception)
    app_frame = cleaned.first
    if app_frame
      source = SourceContext.extract(app_frame)
      meta[:source_context] = source if source
    end
  end

  # ... rest of method ...
end
```

### Config Addition
```ruby
attr_accessor :source_context  # Boolean, default: true
```

### Files Changed

| File | Change |
|------|--------|
| `lib/opentrace/source_context.rb` | **New** — source extraction with caching |
| `lib/opentrace.rb` | Integrate source context into `error` method |
| `lib/opentrace/config.rb` | Add `source_context` attribute |
| `spec/opentrace/source_context_spec.rb` | **New** — extraction, caching, safety tests |

### Benefits
- Errors become self-documenting — no need to open an editor
- File cache prevents repeated disk reads for the same error
- Safety guard ensures only app source is read (never .env, credentials, etc.)
- Server receives `metadata.source_context` as JSON — no schema changes
- ~1ms overhead only on error paths (rare)

### Claude Code Implementation Example
```
User: "Can you check the latest errors in production?"

Claude Code would:
1. Query OpenTrace logs filtered by level=ERROR
2. See the source_context field:
   {
     file: "app/services/payment_processor.rb",
     line: 87,
     context: {
       84: "  def charge(amount)",
       85: "    return if amount <= 0",
       86: "    response = gateway.charge(amount_in_cents: amount * 100)",
       87: "    raise PaymentFailed, response.error_message unless response.success?",
       88: "    response.transaction_id",
       89: "  end"
     }
   }
3. Immediately explain: "The payment gateway is returning an error on line 87.
   The charge call at line 86 is passing amount*100 — check if amount is
   already in cents (double-conversion bug)."
```

---

## 7. Built-in PII Scrubbers

### What
Automatic detection and redaction of personally identifiable information (PII) in metadata before payloads leave the Ruby process. Detects credit card numbers, emails, SSNs, phone numbers, and auth tokens using regex patterns. Runs as part of the `before_send` pipeline.

### Why It Matters
- Developers accidentally log PII all the time (user objects, request params, form data)
- GDPR, CCPA, PCI-DSS compliance requires PII not be stored in logging systems
- Manual `before_send` filters are error-prone — developers forget edge cases
- Sentry and Datadog both offer built-in scrubbers as a compliance feature

### Performance Impact
- **~2μs per payload** — regex scan across all string values in metadata
- **Only runs on the background thread** (in `send_batch`, after `before_send`) — zero request-thread impact
- **Configurable**: can be disabled entirely or tuned to specific patterns
- Skips non-string values (integers, booleans) — no wasted work

### Implementation

**New `pii_scrubber.rb`:**
```ruby
# frozen_string_literal: true

module OpenTrace
  module PiiScrubber
    REDACTED = "[REDACTED]"

    # Patterns with names for configuration
    PATTERNS = {
      credit_card: /\b(?:\d[ -]*?){13,19}\b/,                        # Visa, MC, Amex, etc.
      email: /\b[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Z|a-z]{2,}\b/,
      ssn: /\b\d{3}-?\d{2}-?\d{4}\b/,
      phone: /\b(?:\+?1[-.\s]?)?\(?\d{3}\)?[-.\s]?\d{3}[-.\s]?\d{4}\b/,
      bearer_token: /Bearer\s+[A-Za-z0-9\-._~+\/]+=*/,
      api_key: /\b(?:sk|pk|api[_-]?key)[_-][A-Za-z0-9]{20,}\b/i
    }.freeze

    # Keys whose values should always be fully redacted
    SENSITIVE_KEYS = Set.new(%w[
      password passwd secret token api_key apikey
      authorization auth_token access_token refresh_token
      credit_card card_number cvv ssn
    ]).freeze

    module_function

    # Scrub PII from a payload hash (in-place mutation for performance).
    #
    #   scrub!({ email: "alice@example.com", name: "Alice" })
    #   # => { email: "[REDACTED]", name: "Alice" }
    #
    def scrub!(hash, patterns: nil)
      return hash unless hash.is_a?(Hash)

      active_patterns = patterns || PATTERNS.values

      hash.each do |key, value|
        key_s = key.to_s.downcase
        if SENSITIVE_KEYS.include?(key_s)
          hash[key] = REDACTED
        elsif value.is_a?(String)
          hash[key] = scrub_string(value, active_patterns)
        elsif value.is_a?(Hash)
          scrub!(value, patterns: active_patterns)
        elsif value.is_a?(Array)
          value.each_with_index do |v, i|
            if v.is_a?(String)
              value[i] = scrub_string(v, active_patterns)
            elsif v.is_a?(Hash)
              scrub!(v, patterns: active_patterns)
            end
          end
        end
      end

      hash
    end

    def scrub_string(str, patterns)
      result = str
      patterns.each do |pattern|
        result = result.gsub(pattern, REDACTED)
      end
      result
    end
  end
end
```

**Integration into `client.rb` `send_batch`:**
```ruby
# After before_send and fit_payload:
if @config.pii_scrubbing
  PiiScrubber.scrub!(payload[:metadata], patterns: @active_pii_patterns)
end
```

### Config Addition
```ruby
attr_accessor :pii_scrubbing,       # Boolean, default: false (opt-in)
              :pii_patterns,         # Array of Regexp, additional patterns
              :pii_disabled_patterns # Array of Symbol, patterns to skip (:email, :phone, etc.)
```

### Files Changed

| File | Change |
|------|--------|
| `lib/opentrace/pii_scrubber.rb` | **New** — PII detection and redaction |
| `lib/opentrace/config.rb` | Add `pii_scrubbing`, `pii_patterns`, `pii_disabled_patterns` |
| `lib/opentrace/client.rb` | Apply scrubbing in `send_batch` pipeline |
| `spec/opentrace/pii_scrubber_spec.rb` | **New** — comprehensive PII detection tests |

### Benefits
- Compliance (GDPR, PCI) without manual `before_send` filters
- Catches PII that developers accidentally log
- Runs on background thread — zero request overhead
- Configurable: add custom patterns, disable specific detectors
- Sensitive key redaction catches `params[:password]` even without regex

### Claude Code Implementation Example
```
User: "We need to make sure we're not logging any PII for GDPR compliance"

Claude Code would:
1. Enable PII scrubbing in config/initializers/opentrace.rb:

   OpenTrace.configure do |config|
     config.pii_scrubbing = true
     # Add custom pattern for our internal ID format
     config.pii_patterns = [/\bCUST-\d{8}\b/]
   end

2. Verify with a test:
   OpenTrace.log("INFO", "User signed up", { email: "alice@test.com", name: "Alice" })
   # metadata will contain: { email: "[REDACTED]", name: "Alice" }
```

---

## 8. Automatic Log Trace Injection

### What
A custom log formatter that automatically injects `[trace_id=xxx request_id=yyy]` into every `Rails.logger` output line. This makes standard Rails logs (from gems, middleware, etc.) correlatable with OpenTrace traces without any code changes.

### Why It Matters
- Rails logs from gems (Devise, Sidekiq, Puma) don't include trace IDs — they're orphaned
- When debugging, you need to correlate "this Rails log line happened during this traced request"
- Datadog's log trace injection is a key selling point — it connects their APM to their log management
- Without this, developers must manually grep for timestamps to correlate logs with traces

### Performance Impact
- **~50ns per log line during requests** — two Fiber-local reads (`trace_id`, `request_id`) + string interpolation
- **0ns outside requests** (console, background jobs, boot) — short-circuits on `Fiber[:opentrace_trace_id]` nil check before touching the formatter
- **Zero allocation when no trace context** — skips injection entirely
- Formatter wraps the existing formatter — no monkey-patching of Logger internals

### Implementation

**New `trace_formatter.rb`:**
```ruby
# frozen_string_literal: true

module OpenTrace
  # Wraps an existing log formatter to inject trace context.
  # The injected context appears as a prefix: [trace_id=abc123 request_id=def456]
  #
  # Usage:
  #   Rails.logger.formatter = OpenTrace::TraceFormatter.new(Rails.logger.formatter)
  #
  class TraceFormatter
    def initialize(original_formatter = nil)
      @original = original_formatter || ::Logger::Formatter.new
    end

    def call(severity, datetime, progname, msg)
      trace_prefix = build_trace_prefix
      formatted = @original.call(severity, datetime, progname, msg)

      if trace_prefix && formatted.is_a?(String)
        # Insert after the timestamp/severity prefix, before the message
        formatted.sub(/\n?\z/, " #{trace_prefix}\n")
      else
        formatted
      end
    end

    private

    def build_trace_prefix
      trace_id = Fiber[:opentrace_trace_id]
      return nil unless trace_id

      request_id = Fiber[:opentrace_request_id]
      parts = ["trace_id=#{trace_id}"]
      parts << "request_id=#{request_id}" if request_id
      "[#{parts.join(' ')}]"
    rescue StandardError
      nil
    end
  end
end
```

**Railtie integration (`rails.rb`):**
```ruby
if OpenTrace.config.log_trace_injection
  original = Rails.logger.formatter
  Rails.logger.formatter = OpenTrace::TraceFormatter.new(original)
end
```

### Config Addition
```ruby
attr_accessor :log_trace_injection  # Boolean, default: false (opt-in)
```

### Files Changed

| File | Change |
|------|--------|
| `lib/opentrace/trace_formatter.rb` | **New** — formatter wrapper |
| `lib/opentrace/rails.rb` | Install formatter when `log_trace_injection` is enabled |
| `lib/opentrace/config.rb` | Add `log_trace_injection` attribute |
| `spec/opentrace/trace_formatter_spec.rb` | **New** — formatter tests |

### Benefits
- All Rails logs automatically correlate with OpenTrace traces
- Third-party gem logs (Devise, Sidekiq, etc.) get trace context for free
- Server can parse `trace_id=xxx` from plain-text log lines
- Zero code changes required — just enable the config flag

### Claude Code Implementation Example
```
User: "I can't correlate our Rails logs with OpenTrace traces"

Claude Code would:
1. Enable trace injection:

   OpenTrace.configure do |config|
     config.log_trace_injection = true
   end

2. Now every Rails log line includes trace context:
   [2026-02-13 10:15:42] INFO  Processing by UsersController#show [trace_id=abc123def456 request_id=req-789]
   [2026-02-13 10:15:42] DEBUG  User Load (0.3ms) [trace_id=abc123def456 request_id=req-789]

3. Search OpenTrace by trace_id=abc123def456 to see the full traced request
```

---

## 9. Session Tracking

### What
Capture the user's session ID from cookies and track session-level health (how many requests errored vs succeeded within a session). This groups multiple requests into a "user session" for understanding the user experience.

### Why It Matters
- A single error might not be a problem, but 5 errors in one session means a frustrated user
- Session tracking lets you answer "how many user sessions were impacted by this bug?"
- Sentry's session health is a key metric for release quality decisions
- Without this, you can only count individual errors — not affected users/sessions

### Performance Impact
- **~20ns per request** — one `env["rack.session.options"]` read + one `env["HTTP_COOKIE"]` regex
- **Zero cost when cookies aren't present** (API endpoints, health checks)
- Session ID is just another metadata field — no additional network calls

### Implementation

**Middleware integration (`middleware.rb`):**
```ruby
def call(env)
  # ... existing code ...

  if OpenTrace.config.session_tracking
    session_id = extract_session_id(env)
    Fiber[:opentrace_session_id] = session_id if session_id
  end

  # ... rest of call ...
ensure
  # ... existing cleanup ...
  Fiber[:opentrace_session_id] = nil
end

private

def extract_session_id(env)
  # Try Rack session first
  if (session = env["rack.session"])
    return session.id.to_s if session.respond_to?(:id) && session.id
  end

  # Fall back to session cookie
  cookie_name = env["rack.session.options"]&.dig(:key) || "_session_id"
  cookies = env["HTTP_COOKIE"]
  if cookies
    match = cookies.match(/#{Regexp.escape(cookie_name)}=([^;]+)/)
    return match[1] if match
  end

  nil
rescue StandardError
  nil
end
```

**PayloadBuilder includes session_id in metadata:**
```ruby
meta[:session_id] = entry[XX] if entry[XX]  # session_id slot in deferred array
```

### Config Addition
```ruby
attr_accessor :session_tracking  # Boolean, default: false (opt-in)
```

### Files Changed

| File | Change |
|------|--------|
| `lib/opentrace/middleware.rb` | Extract session ID, store in Fiber-local |
| `lib/opentrace/config.rb` | Add `session_tracking` attribute |
| `lib/opentrace/rails.rb` | Capture `Fiber[:opentrace_session_id]` in `:request` array |
| `spec/opentrace/session_tracking_spec.rb` | **New** — session extraction tests |

### Benefits
- Enables "affected sessions" metrics on the server
- Groups requests into user journeys
- Session ID in metadata enables server-side session health dashboards
- Opt-in, zero cost when disabled

### Claude Code Implementation Example
```
User: "How many users were affected by the payment bug last hour?"

Claude Code would:
1. Query OpenTrace: level=ERROR AND metadata.exception_class=PaymentFailed AND last_1h
2. Count distinct metadata.session_id values
3. Report: "The PaymentFailed error affected 23 unique user sessions in the last hour
   (from 847 total errors — meaning ~3% of sessions saw errors)"
```

---

## 10. Duplicate Query Detection

### What
Detect truly identical SQL queries within a single request (same normalized query executed multiple times). This is real N+1 detection — not just "more than 20 queries" but "the exact same query ran 50 times with different IDs."

### Why It Matters
- The current N+1 detection (`sql_count > 20`) is a blunt instrument — it flags requests with many DIFFERENT queries too
- True N+1 means the SAME query template runs repeatedly (e.g., `SELECT * FROM users WHERE id = ?` in a loop)
- This is the #1 performance problem in Rails apps and the current detection misses the pattern
- Datadog and AppSignal both detect duplicate query patterns

### Performance Impact
- **~100ns per query** — one hash table lookup + increment on the request thread
- Uses the SQL fingerprint (from Feature #4) or a simplified inline hash
- **Bounded memory**: stores only fingerprint → count (not full SQL), max 100 unique fingerprints per request
- **Only active when RequestCollector is present** (sampled requests with `request_summary: true`)

### Implementation

**RequestCollector additions:**
```ruby
class RequestCollector
  def initialize(max_timeline: MAX_TIMELINE_EVENTS)
    # ... existing code ...
    @sql_fingerprints = {}  # fingerprint => count
  end

  def record_sql(name:, duration_ms:, table: nil, fingerprint: nil)
    # ... existing code ...

    # Track duplicate queries
    if fingerprint && @sql_fingerprints.size < 100
      @sql_fingerprints[fingerprint] = (@sql_fingerprints[fingerprint] || 0) + 1
    end
  end

  def summary
    result = {
      # ... existing fields ...
    }

    # Duplicate query detection
    duplicates = @sql_fingerprints.select { |_, count| count > 1 }
    unless duplicates.empty?
      result[:duplicate_queries] = duplicates.size
      result[:worst_duplicate_count] = duplicates.values.max
      # Include top 3 most-repeated fingerprints
      result[:top_duplicates] = duplicates
        .sort_by { |_, count| -count }
        .first(3)
        .map { |fp, count| { fingerprint: fp, count: count } }
      result[:n_plus_one_warning] = true if duplicates.values.max > 5
    end

    result.compact
  end
end
```

**Railtie SQL subscriber passes fingerprint:**
```ruby
# In the sql.active_record subscriber:
if collector
  fp = simple_sql_fingerprint(raw_sql) if raw_sql
  collector.record_sql(name: sql_name, duration_ms: duration_ms, fingerprint: fp)
end

def simple_sql_fingerprint(sql)
  # Quick normalization: strip literals, hash the result
  normalized = sql.gsub(/'[^']*'/, "?").gsub(/\b\d+\b/, "?")
  Digest::MD5.hexdigest(normalized)[0, 8]
rescue StandardError
  nil
end
```

### Files Changed

| File | Change |
|------|--------|
| `lib/opentrace/request_collector.rb` | Add `@sql_fingerprints`, duplicate detection in `summary` |
| `lib/opentrace/rails.rb` | Pass `fingerprint:` to `record_sql` |
| `spec/opentrace/duplicate_query_spec.rb` | **New** — duplicate detection tests |

### Benefits
- True N+1 detection — identifies the exact query pattern, not just "too many queries"
- Fingerprint counts enable "this query ran 47 times" warnings
- Top duplicates in request_summary make N+1 issues obvious in the dashboard
- Works with existing request_summary — no server schema changes

### Claude Code Implementation Example
```
User: "Our orders page is slow"

Claude Code would:
1. Check OpenTrace request_summary for GET /orders:
   {
     sql_count: 52,
     duplicate_queries: 1,
     worst_duplicate_count: 50,
     top_duplicates: [
       { fingerprint: "a3f2b1c4", count: 50 }
     ],
     n_plus_one_warning: true
   }
2. Correlate fingerprint "a3f2b1c4" with SQL logs:
   "SELECT * FROM products WHERE id = ?"
3. Fix: "You have a classic N+1 — loading 50 products one by one.
   Add `includes(:product)` to your orders query."
```

---

## 11. Lifecycle Callbacks

### What
Additional callback hooks beyond `before_send`: `on_error` (called when an error is captured), `after_send` (called after a batch is successfully delivered), and `before_breadcrumb` (filter/modify breadcrumbs).

### Why It Matters
- `on_error` enables custom alerting logic (page PagerDuty, post to Slack) without a separate error monitoring service
- `after_send` enables delivery confirmation for compliance-critical logging
- `before_breadcrumb` enables scrubbing sensitive data from breadcrumbs before they're attached to errors
- Sentry offers all three — they're commonly used in production Rails apps

### Performance Impact
- **~10ns per hook invocation** — nil check + Proc.call
- **Zero cost when not configured** — `@config.on_error&.call(...)` short-circuits on nil
- All callbacks are fire-and-forget (wrapped in rescue) — never slow down the pipeline
- `after_send` runs on the background thread — zero request impact

### Implementation

**Config additions:**
```ruby
attr_accessor :on_error,           # Proc(exception, metadata) — called on every error capture
              :after_send,         # Proc(batch_size, bytes) — called after successful delivery
              :before_breadcrumb   # Proc(Breadcrumb) -> Breadcrumb|nil — filter breadcrumbs
```

**Integration points:**

```ruby
# In opentrace.rb error():
def error(exception, metadata = {})
  # ... existing code ...
  config.on_error&.call(exception, meta) rescue nil
  log("ERROR", exception.message.to_s, meta)
end

# In client.rb handle_response():
when Net::HTTPSuccess
  # ... existing stats code ...
  @config.after_send&.call(batch.size, bytes) rescue nil

# In opentrace.rb add_breadcrumb():
if config.before_breadcrumb
  crumb = config.before_breadcrumb.call(crumb) rescue crumb
  return unless crumb
end
```

### Files Changed

| File | Change |
|------|--------|
| `lib/opentrace/config.rb` | Add `on_error`, `after_send`, `before_breadcrumb` |
| `lib/opentrace.rb` | Call `on_error` in `error` method |
| `lib/opentrace/client.rb` | Call `after_send` in `handle_response` |
| `spec/opentrace/callbacks_spec.rb` | **New** — callback invocation tests |

### Benefits
- Custom alerting without external dependencies
- Delivery confirmation for audit logging requirements
- Breadcrumb scrubbing for PII compliance
- All callbacks are safe (rescue-wrapped) — can never break the app

### Claude Code Implementation Example
```
User: "I want to send a Slack notification for every 500 error"

Claude Code would:
1. Add the on_error callback:

   OpenTrace.configure do |config|
     config.on_error = ->(exception, metadata) {
       if metadata[:status].to_i >= 500
         SlackNotifier.post(
           channel: "#errors",
           text: "500 Error: #{exception.class} — #{exception.message}"
         )
       end
     }
   end

2. Errors are still captured normally, and Slack gets notified too
```

---

## 12. Unix Socket Transport

### What
An alternative transport that sends payloads over a Unix domain socket instead of TCP/HTTP. For deployments where the OpenTrace server runs on the same host, this eliminates TCP handshake, TLS overhead, and HTTP framing — dropping per-batch latency from ~5ms to ~0.5ms.

### Why It Matters
- Self-hosted OpenTrace servers often run on the same machine as the Rails app
- TCP has inherent overhead: connection setup, TLS negotiation, HTTP headers
- Unix sockets are 2-5x faster for local IPC — proven by Datadog's agent architecture
- Reduces the window where the background thread is blocked, freeing it for more batches

### Performance Impact
- **Saves ~0.5-4ms per batch** vs HTTP (no TCP/TLS/HTTP overhead)
- **Only affects background thread** — zero change to request-thread performance
- Falls back to HTTP automatically if socket is unavailable
- Same batching, compression, and retry logic — just a different transport

### Implementation

**Config addition:**
```ruby
attr_accessor :transport,     # :http (default) | :unix_socket
              :socket_path    # String, path to Unix socket (default: "/tmp/opentrace.sock")
```

**New transport in `client.rb`:**
```ruby
def send_payload(json, batch_id:)
  case @config.transport
  when :unix_socket
    unix_socket_send(json, batch_id: batch_id)
  else
    http_post(json, batch_id: batch_id)
  end
end

def unix_socket_send(json, batch_id: nil)
  socket = UNIXSocket.new(@config.socket_path)
  # Simple protocol: 4-byte length prefix + JSON
  payload = json
  if @config.compression && json.bytesize > @config.compression_threshold
    payload = gzip_compress(json)
  end
  header = [payload.bytesize, batch_id || ""].pack("NA*")
  socket.write(header)
  socket.write(payload)
  socket.flush

  # Read response
  response_data = socket.read(4)
  status = response_data&.unpack1("N") || 500
  socket.close

  # Return a mock response object for handle_response compatibility
  UnixSocketResponse.new(status)
rescue Errno::ECONNREFUSED, Errno::ENOENT
  # Socket not available — fall back to HTTP
  http_post(json, batch_id: batch_id)
end

UnixSocketResponse = Struct.new(:code) do
  def is_a?(klass)
    case code
    when 200..299 then klass == Net::HTTPSuccess
    when 429 then klass == Net::HTTPTooManyRequests
    when 401 then klass == Net::HTTPUnauthorized
    when 500..599 then klass == Net::HTTPServerError
    else false
    end
  end
end
```

### Files Changed

| File | Change |
|------|--------|
| `lib/opentrace/config.rb` | Add `transport`, `socket_path` attributes |
| `lib/opentrace/client.rb` | Add `unix_socket_send`, `UnixSocketResponse`, transport dispatch |
| `spec/opentrace/unix_socket_spec.rb` | **New** — socket transport tests |

### Benefits
- 2-5x faster payload delivery for co-located deployments
- Same reliability guarantees (retry, circuit breaker, backpressure)
- Automatic HTTP fallback if socket is unavailable
- Requires corresponding Unix socket listener on the Go server (future server feature)

### Claude Code Implementation Example
```
User: "Our OpenTrace server runs on the same box — can we make delivery faster?"

Claude Code would:
1. Update config:

   OpenTrace.configure do |config|
     config.transport = :unix_socket
     config.socket_path = "/var/run/opentrace.sock"
   end

2. Note: "The Go server needs a Unix socket listener too — I'll add that
   to the server config. Falls back to HTTP automatically if the socket
   isn't available yet."
```

---

## 13. Local Variables Capture

### What
When an error occurs, capture the local variable bindings at the crash point. The developer passes their `binding` explicitly via `OpenTrace.capture_binding(e, binding)` in rescue blocks. This lets you see the exact state of variables when the exception was raised.

### Why It Matters
- Stack traces show WHERE the error happened but not the STATE of the program
- Sentry's local variables capture is their most powerful debugging feature
- Without this, developers must reproduce errors locally to inspect variable state
- Particularly valuable for rare, hard-to-reproduce bugs

### Performance Impact
- **~5μs per explicit `capture_binding` call** — `binding.local_variables` + `binding.local_variable_get`
- **Zero cost on non-error paths** — only activated in user's rescue blocks
- **Zero global overhead** — no TracePoint, no VM hooks, no invisible cost per `raise`
- Capped at 10 variables, 500 chars per value — prevents memory bloat

> **Why NOT TracePoint?**
>
> A `TracePoint.new(:raise)` approach would fire on **every single `raise` in the Ruby VM** — not just application errors. Ruby uses exceptions internally for control flow: `StopIteration` from `Enumerator` (every `.map`, `.each`, `.find`), `Errno::EAGAIN` in non-blocking IO, `Timeout::Error` in connection pools, and ActiveRecord raises/rescues during connection checkout. A typical Rails request raises **50-100 internal exceptions**. At ~5μs each, that's **250-500μs of invisible overhead on every request** — even when no real errors occur. This violates our "never affect the host app" invariant, so we use explicit capture instead.

### Implementation

**New `local_vars.rb`:**
```ruby
# frozen_string_literal: true

module OpenTrace
  module LocalVars
    MAX_VARS = 10
    MAX_VALUE_LENGTH = 500

    module_function

    # Capture local variables from an explicit binding.
    # Called by the user in their rescue blocks:
    #
    #   rescue => e
    #     OpenTrace.capture_binding(e, binding)
    #     raise
    #   end
    #
    # Returns: Array of { name:, value:, type: } or nil
    def capture(binding_obj)
      return nil unless binding_obj.is_a?(Binding)

      vars = binding_obj.local_variables.first(MAX_VARS)
      vars.filter_map do |name|
        # Skip internal variables (_, _1, etc.)
        next if name.to_s.start_with?("_")

        value = binding_obj.local_variable_get(name)
        {
          name: name.to_s,
          value: safe_inspect(value),
          type: value.class.name
        }
      end
    rescue StandardError
      nil
    end

    def safe_inspect(value)
      str = value.inspect
      str.length > MAX_VALUE_LENGTH ? str[0, MAX_VALUE_LENGTH] + "..." : str
    rescue StandardError
      "#<uninspectable>"
    end
  end
end
```

**New public API in `opentrace.rb`:**
```ruby
module OpenTrace
  class << self
    # Capture local variables from a rescue block's binding and attach
    # them to the exception for the next OpenTrace.error() call.
    #
    #   rescue => e
    #     OpenTrace.capture_binding(e, binding)
    #     OpenTrace.error(e)
    #     raise
    #   end
    #
    # This is explicit and opt-in — no global VM hooks, no TracePoint,
    # no invisible overhead on every raise in the application.
    def capture_binding(exception, binding_obj)
      return unless enabled? && config.local_vars_capture

      vars = LocalVars.capture(binding_obj)
      if vars && !vars.empty?
        exception.instance_variable_set(:@__opentrace_local_vars__, vars)
      end
    rescue StandardError
      # Never raise
    end
  end
end
```

**Integration into `error` method:**
```ruby
def error(exception, metadata = {})
  # ... existing code ...

  # Attach captured local variables (if capture_binding was called)
  if config.local_vars_capture && exception.instance_variable_defined?(:@__opentrace_local_vars__)
    meta[:local_variables] = exception.instance_variable_get(:@__opentrace_local_vars__)
  end

  log("ERROR", exception.message.to_s, meta)
end
```

### Config Addition
```ruby
attr_accessor :local_vars_capture  # Boolean, default: false (opt-in, security-sensitive)
```

### Files Changed

| File | Change |
|------|--------|
| `lib/opentrace/local_vars.rb` | **New** — explicit binding-based variable capture |
| `lib/opentrace.rb` | Add `capture_binding` method, integrate into `error` |
| `spec/opentrace/local_vars_spec.rb` | **New** — capture tests with safety bounds |

### Benefits
- See the exact state of variables when an error occurred
- Dramatically reduces time-to-debug for rare/intermittent errors
- **No global VM hooks** — zero overhead unless the user calls `capture_binding` in their rescue
- Security-safe: opt-in, capped values, skip internal variables
- ~5μs cost only at the explicit capture point (not on every raise in the VM)

### Claude Code Implementation Example
```
User: "I have a rare bug where user.name is sometimes nil but I can't reproduce it"

Claude Code would:
1. Enable local vars capture:

   OpenTrace.configure do |config|
     config.local_vars_capture = true
   end

2. Add explicit capture to the failing code:

   def update_profile(user, params)
     user.update!(params)
   rescue ActiveRecord::RecordInvalid => e
     OpenTrace.capture_binding(e, binding)
     OpenTrace.error(e, { action: "update_profile" })
     raise
   end

3. Wait for the error to recur, then check the captured locals:
   {
     local_variables: [
       { name: "user", value: "#<User id: 42, name: nil, ...>", type: "User" },
       { name: "params", value: '{"name"=>""}', type: "Hash" }
     ]
   }
4. Identify: "The user's name is being set to nil because params[:name] is
   an empty string and your model has `attribute :name, default: nil`."
```

---

## 14. EXPLAIN Plan Capture

### What
Automatically run `EXPLAIN` on SQL queries that exceed a configurable duration threshold and include the execution plan in the log entry. This shows whether the query is doing a full table scan, missing an index, or has a bad join order.

### Why It Matters
- Slow queries are a top-3 cause of production performance issues
- Developers need EXPLAIN output to know WHY a query is slow — duration alone isn't enough
- Running EXPLAIN manually requires production database access (which many developers don't have)
- Datadog's "Explain Plans" feature is heavily used by their APM customers

### Performance Impact
- **0ns on the request thread** — SQL text is captured into the deferred array; EXPLAIN runs on background thread
- **~2-10ms per slow query on the background thread** — uses a separate DB connection from the pool
- **Only triggers above threshold** (default: 100ms) — most queries are fast and skip this
- **Opt-in** — disabled by default to avoid any production risk
- Rate-limited: max 3 EXPLAIN queries per batch cycle to prevent DB pressure

> **Why NOT on the request thread?**
>
> Running `EXPLAIN` on the request thread would add 2-10ms to an already-slow request (making slow requests slower). It would also hold the DB connection longer, reducing pool availability. By deferring to the background thread with a separate connection checkout, the request finishes at normal speed and the EXPLAIN result is attached asynchronously.

### Implementation

**Request thread (rails.rb) — only captures the SQL text:**
```ruby
# In the sql.active_record subscriber, after duration calculation:
if OpenTrace.config.explain_slow_queries &&
   duration_ms > OpenTrace.config.explain_threshold_ms &&
   explainable_query?(raw_sql)

  # Flag the SQL text for background EXPLAIN — zero request-thread DB work
  Fiber[:opentrace_pending_explains] ||= []
  if Fiber[:opentrace_pending_explains].size < 3  # cap per request
    Fiber[:opentrace_pending_explains] << {
      sql: raw_sql,
      duration_ms: duration_ms,
      name: sql_name
    }
  end
end

def explainable_query?(sql)
  sql && (sql.start_with?("SELECT") || sql.start_with?("select"))
end
```

**Middleware captures pending explains into the :request array:**
```ruby
ensure
  # ... existing cleanup ...
  Fiber[:opentrace_pending_explains] = nil
```

**Background thread (PayloadBuilder or Client) — runs EXPLAIN with its own connection:**
```ruby
# In materialize_request or as a post-materialization step:
if pending_explains && !pending_explains.empty? && defined?(ActiveRecord::Base)
  explain_results = pending_explains.filter_map do |entry|
    explain_output = run_explain(entry[:sql])
    next unless explain_output
    {
      sql: entry[:sql].slice(0, 500),
      duration_ms: entry[:duration_ms],
      name: entry[:name],
      explain_plan: explain_output
    }
  end
  meta[:explain_plans] = explain_results unless explain_results.empty?
end

def run_explain(sql)
  ActiveRecord::Base.connection_pool.with_connection do |conn|
    result = conn.execute("EXPLAIN #{sql}")
    rows = result.map { |row| row.values.join(" | ") }
    rows.join("\n").slice(0, 2000)
  end
rescue StandardError
  nil
end
```

### Config Addition
```ruby
attr_accessor :explain_slow_queries,  # Boolean, default: false
              :explain_threshold_ms   # Float, default: 100.0
```

### Files Changed

| File | Change |
|------|--------|
| `lib/opentrace/config.rb` | Add `explain_slow_queries`, `explain_threshold_ms` |
| `lib/opentrace/rails.rb` | Capture slow SQL text (no EXPLAIN on request thread) |
| `lib/opentrace/middleware.rb` | Clear `Fiber[:opentrace_pending_explains]` |
| `lib/opentrace/payload_builder.rb` | Run EXPLAIN on background thread with separate connection |
| `spec/opentrace/explain_spec.rb` | **New** — EXPLAIN capture tests |

### Benefits
- Automatic EXPLAIN for slow queries — no manual database access needed
- **Zero request-thread overhead** — EXPLAIN runs asynchronously on background thread
- Uses a separate DB connection (connection pool checkout), never holds the request's connection
- Rate-limited (max 3 per request) to prevent cascading DB load
- Opt-in, disabled by default — safe for production

### Claude Code Implementation Example
```
User: "There's a slow query on the users page but I don't have prod DB access"

Claude Code would:
1. Enable EXPLAIN capture:

   OpenTrace.configure do |config|
     config.explain_slow_queries = true
     config.explain_threshold_ms = 50.0  # catch queries over 50ms
   end

2. Check the captured explain plan in OpenTrace:
   {
     explain_plans: [{
       sql: "SELECT * FROM orders WHERE user_id = 42 ORDER BY created_at DESC",
       duration_ms: 87.3,
       explain_plan: "Seq Scan on orders  (cost=0.00..45892.00 rows=12 width=380)\n  Filter: (user_id = 42)"
     }]
   }
3. Diagnose: "It's doing a sequential scan on orders. Add an index:
   `add_index :orders, [:user_id, :created_at]`"
```

---

## 15. GC / Runtime Metrics

### What
Periodic collection of Ruby runtime metrics: GC statistics (major/minor collections, heap slots, malloc increase), thread count, and process RSS. Collected on a background timer and sent as structured events.

### Why It Matters
- Memory bloat and GC pressure are silent performance killers in Ruby
- Without runtime metrics, you can't correlate request latency spikes with GC pauses
- Datadog and AppSignal both collect runtime metrics automatically
- Essential for capacity planning (thread count, memory growth)

### Performance Impact
- **~10μs every 30 seconds** — reads `GC.stat` + `/proc/self/statm` (Linux) on a background thread
- **Zero request-thread impact** — runs entirely in a separate timer thread
- **Configurable interval** — default 30s, can be set higher for lower overhead
- Uses existing `OpenTrace.event` — no new transport mechanism

### Implementation

**New `runtime_monitor.rb`:**
```ruby
# frozen_string_literal: true

module OpenTrace
  class RuntimeMonitor
    DEFAULT_INTERVAL = 30 # seconds

    def initialize(interval: DEFAULT_INTERVAL)
      @interval = interval
      @thread = nil
      @running = false
    end

    def start
      return if @running
      @running = true
      @thread = Thread.new { monitor_loop }
      @thread.abort_on_exception = false
      @thread.report_on_exception = false
    end

    def stop
      @running = false
      @thread&.join(2)
    end

    private

    def monitor_loop
      while @running
        sleep @interval
        next unless @running && OpenTrace.enabled?
        collect_and_send
      end
    rescue StandardError
      # Swallow
    end

    def collect_and_send
      gc = GC.stat
      metrics = {
        # GC metrics
        gc_count: gc[:count],
        gc_major_count: gc[:major_gc_count],
        gc_minor_count: gc[:minor_gc_count],
        gc_heap_live_slots: gc[:heap_live_slots],
        gc_heap_free_slots: gc[:heap_free_slots],
        gc_heap_allocated_pages: gc[:heap_allocated_pages],
        gc_malloc_increase_bytes: gc[:malloc_increase_bytes],
        gc_oldmalloc_increase_bytes: gc[:oldmalloc_increase_bytes],

        # Thread metrics
        thread_count: Thread.list.count,

        # Process metrics
        process_rss_mb: current_rss_mb,
        process_pid: Process.pid
      }.compact

      OpenTrace.event("runtime.metrics", "Runtime metrics snapshot", metrics)
    rescue StandardError
      # Swallow
    end

    def current_rss_mb
      if RUBY_PLATFORM.include?("linux")
        File.read("/proc/self/statm").split[1].to_i * 4096.0 / 1024 / 1024
      else
        gc = GC.stat
        gc[:heap_live_slots].to_f * 40 / 1024 / 1024
      end
    rescue StandardError
      nil
    end
  end
end
```

**Railtie integration (`rails.rb`):**
```ruby
if OpenTrace.config.runtime_metrics
  require_relative "runtime_monitor"
  @runtime_monitor = OpenTrace::RuntimeMonitor.new(
    interval: OpenTrace.config.runtime_metrics_interval
  )
  @runtime_monitor.start
end
```

### Config Addition
```ruby
attr_accessor :runtime_metrics,          # Boolean, default: false (opt-in)
              :runtime_metrics_interval  # Integer (seconds), default: 30
```

### Files Changed

| File | Change |
|------|--------|
| `lib/opentrace/runtime_monitor.rb` | **New** — GC/thread/memory metrics collector |
| `lib/opentrace/config.rb` | Add `runtime_metrics`, `runtime_metrics_interval` |
| `lib/opentrace/rails.rb` | Start RuntimeMonitor when enabled |
| `spec/opentrace/runtime_monitor_spec.rb` | **New** — metrics collection tests |

### Benefits
- Correlate GC pauses with request latency spikes
- Track memory growth over time for leak detection
- Thread count monitoring for concurrency issues
- All metrics sent as standard events — server displays them in dashboards
- Background thread, zero request impact

### Claude Code Implementation Example
```
User: "Our app gets slow every few minutes and we don't know why"

Claude Code would:
1. Enable runtime metrics:

   OpenTrace.configure do |config|
     config.runtime_metrics = true
     config.runtime_metrics_interval = 10  # every 10s for debugging
   end

2. Analyze the metrics in OpenTrace:
   - gc_major_count spikes every 3 minutes (major GC pauses)
   - gc_malloc_increase_bytes growing steadily (memory leak)
   - process_rss_mb: 512 -> 1024 over 30 minutes

3. Diagnose: "You have a memory leak causing frequent major GC pauses.
   The malloc_increase_bytes metric shows it's native memory (likely
   an image processing gem or C extension). Check if you're closing
   all file handles and freeing Tempfile objects."
```

---

## Implementation Order

Recommended implementation sequence based on dependencies and value:

### Phase 1: Core Instrumentation (Features 1-6)
These are the highest-value features and are mostly independent.

1. **Feature 4: SQL Normalization** — prerequisite for Feature 10
2. **Feature 2: Exception Cause Chaining** — small, high-value, no dependencies
3. **Feature 5: Transaction Naming** — small, high-value, no dependencies
4. **Feature 1: Custom Instrumentation API** — high-value, depends on existing Span/Trace infra
5. **Feature 3: Breadcrumbs API** — high-value, pairs well with Feature 6
6. **Feature 6: Source Code Context** — high-value for error debugging

### Phase 2: Data Protection & Delivery (Features 7-9, 12)
These improve data quality and delivery reliability.

7. **Feature 7: PII Scrubbers** — important for compliance
8. **Feature 8: Log Trace Injection** — small, high-value
9. **Feature 9: Session Tracking** — small, enables session-level analysis
10. **Feature 12: Unix Socket Transport** — requires Go server changes too

### Phase 3: Advanced Analysis (Features 10-11, 13-15)
These are powerful but depend on earlier features.

11. **Feature 10: Duplicate Query Detection** — depends on Feature 4 (normalization)
12. **Feature 11: Lifecycle Callbacks** — depends on Feature 3 (before_breadcrumb)
13. **Feature 13: Local Variables Capture** — opt-in, security-sensitive
14. **Feature 14: EXPLAIN Plan Capture** — opt-in, production-risk-sensitive
15. **Feature 15: Runtime Metrics** — independent, but lower priority

---

## Server-Side Requirements

Most features need **no server changes** — they store data in `metadata` (JSON blob). Features that benefit from server-side awareness:

| Feature | Server Change Needed? | Details |
|---------|----------------------|---------|
| 1. Custom Instrumentation | No | Spans stored as log entries with `metadata.span_*` |
| 2. Exception Chaining | No | Causes stored in `metadata.exception_causes` |
| 3. Breadcrumbs | No | Stored in `metadata.breadcrumbs` |
| 4. SQL Normalization | Optional | Server could group by `metadata.sql_fingerprint` |
| 5. Transaction Naming | Optional | Server could group by `metadata.transaction_name` |
| 6. Source Code Context | No | Stored in `metadata.source_context` |
| 7. PII Scrubbers | No | Client-side only |
| 8. Log Trace Injection | No | Client-side only |
| 9. Session Tracking | Optional | Server could aggregate by `metadata.session_id` |
| 10. Duplicate Queries | No | Stored in `request_summary.top_duplicates` |
| 11. Lifecycle Callbacks | No | Client-side only |
| 12. Unix Socket | **Yes** | Go server needs a Unix socket listener |
| 13. Local Variables | No | Stored in `metadata.local_variables` |
| 14. EXPLAIN Plans | No | Stored in `metadata.explain_plan` |
| 15. Runtime Metrics | No | Sent as `event_type: "runtime.metrics"` |

---

## Version Plan

| Version | Features | Theme |
|---------|----------|-------|
| v0.9.0 | 2, 4, 5, 8 | Quick wins (small, high-value) |
| v0.10.0 | 1, 3, 6 | Core instrumentation |
| v0.11.0 | 7, 9, 10, 11 | Data quality + analysis |
| v0.12.0 | 12, 13, 14, 15 | Advanced features |
