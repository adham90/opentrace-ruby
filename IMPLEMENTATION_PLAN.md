# OpenTrace Ruby Gem — Enhanced Instrumentation Plan

## Goal

Enrich the JSON payload sent to the OpenTrace server so the AI watcher can autonomously investigate errors by correlating logs with database data, request inputs, and job context — without requiring manual developer annotation.

---

## Phase 1: Enrich the Existing `process_action` Subscriber

**Files modified:** `lib/opentrace/rails.rb`
**Risk:** Low — we're extracting more data from an event we already subscribe to.

### 1A. Exception Auto-Capture

The `process_action.action_controller` event already carries `exception` and `exception_object` keys when a request raises. We just aren't reading them.

**Add to metadata in `forward_request_log`:**

```ruby
# payload[:exception] is ["ClassName", "message"] when present
if payload[:exception]
  metadata[:exception_class]   = payload[:exception][0]
  metadata[:exception_message] = truncate(payload[:exception][1], 500)
end

if payload[:exception_object]&.backtrace
  cleaned = clean_backtrace(payload[:exception_object].backtrace)
  metadata[:backtrace] = cleaned.first(15)
end
```

**Helper methods to add (private, on Railtie):**

```ruby
def truncate(str, max)
  return str if str.nil? || str.length <= max
  str[0, max] + "..."
end

def clean_backtrace(backtrace)
  if defined?(::Rails) && ::Rails.respond_to?(:backtrace_cleaner)
    ::Rails.backtrace_cleaner.clean(backtrace)
  else
    backtrace.reject { |line| line.include?("/gems/") }
  end
end
```

**Level logic update:** If `payload[:exception]` is present, log as `ERROR` regardless of status code (some exceptions result in 200 due to rescue_from).

### 1B. Request Params (Filtered)

The event payload contains `params`. We should use the controller's `request.filtered_parameters` which respects `config.filter_parameters` (passwords, tokens, etc.).

**Add to metadata:**

```ruby
if (controller = payload[:controller_instance])
  if controller.respond_to?(:request, true) && controller.request.respond_to?(:filtered_parameters)
    params = controller.request.filtered_parameters
    params = params.except("controller", "action") # remove routing noise
    metadata[:params] = truncate_hash(params, 2048) unless params.empty?
  end
end
```

**`truncate_hash` helper** — serialize to JSON, if > max bytes, truncate the string representation:

```ruby
def truncate_hash(hash, max_bytes)
  json = JSON.generate(hash)
  return hash if json.bytesize <= max_bytes
  JSON.parse(json[0, max_bytes - 20] + "...\"}")  # safe truncation
rescue
  { _truncated: true, _size: json.bytesize }
end
```

### 1C. Adjust Log Level Logic

Current:
```ruby
level = payload[:status].to_i >= 500 ? "ERROR" : "INFO"
```

Proposed:
```ruby
level = if payload[:exception]
          "ERROR"
        elsif payload[:status].to_i >= 500
          "ERROR"
        elsif payload[:status].to_i >= 400
          "WARN"
        else
          "INFO"
        end
```

This gives the AI three signal tiers: ERROR (broken), WARN (client issue, worth correlating), INFO (normal).

### Phase 1 Tests

Add to `spec/integration/rails_spec.rb`:

1. **Exception capture** — Instrument with `exception: ["ActiveRecord::RecordNotFound", "Couldn't find Order with id=99"]` and `exception_object:` with a backtrace, verify `exception_class`, `exception_message`, `backtrace` in metadata.
2. **Params capture** — Create a controller stub that exposes `request.filtered_parameters`, verify `params` in metadata, verify "controller"/"action" keys are stripped.
3. **Params filtering** — Verify that the raw `params` hash from the event payload is NOT used (only filtered version).
4. **4xx logs as WARN** — Instrument with status 422, verify level is `WARN`.
5. **Exception overrides status** — Instrument with status 200 + exception, verify level is `ERROR`.
6. **Truncation** — Pass a very large params hash, verify metadata stays under a reasonable size.

---

## Phase 2: User Config — Context Injection & Level Filtering

**Files modified:** `lib/opentrace/config.rb`, `lib/opentrace.rb`
**Risk:** Very low — additive, no behavior change for existing users.

### Problem 1: No User Context

Currently the gem only captures `user_id` inside the `process_action` Rails subscriber via `current_user.id`. This means:
- Manual `OpenTrace.log()` calls have no user context
- SQL and Job subscribers won't have user context either
- There's no way to inject account_id, session_id, tenant, or any custom per-request identifier

### Problem 2: No Level Filtering

The gem sends every log to the server regardless of level. Users have no way to say "only send WARN and above" to reduce noise and bandwidth. This becomes critical once Phase 4 adds DEBUG-level SQL logs — without filtering, a busy app could flood the server with thousands of SQL entries per minute.

### Solution: `config.context` — accepts a Hash or a Proc

```ruby
# Static context — simplest, no proc syntax needed
OpenTrace.configure do |c|
  c.context = { tenant: "acme", region: "us-east" }
end

# Dynamic context — proc evaluated per log call, reads from thread-safe source
OpenTrace.configure do |c|
  c.context = -> {
    {
      user_id:    Current.user&.id,
      account_id: Current.account&.id,
      session_id: Current.session&.id
    }
  }
end
```

### 2A. Config Changes

Add to `Config`:

```ruby
attr_accessor :context, :min_level

LEVELS = { debug: 0, info: 1, warn: 2, error: 3, fatal: 4 }.freeze

def initialize
  # ... existing fields ...
  @context   = nil    # nil | Hash | Proc
  @min_level = :debug # send everything by default
end

def min_level_value
  LEVELS[min_level.to_s.downcase.to_sym] || 0
end
```

Usage — one line to filter:

```ruby
OpenTrace.configure do |c|
  c.min_level = :warn   # only send WARN, ERROR, FATAL to OpenTrace
end

# or per environment:
OpenTrace.configure do |c|
  c.min_level = Rails.env.production? ? :info : :debug
end
```

### 2B. Private Helpers in `OpenTrace` Module

```ruby
LEVEL_VALUES = { "DEBUG" => 0, "INFO" => 1, "WARN" => 2, "ERROR" => 3, "FATAL" => 4 }.freeze

def level_meets_threshold?(level)
  LEVEL_VALUES[level.to_s.upcase].to_i >= config.min_level_value
end

def resolve_context
  case config.context
  when Proc then config.context.call
  when Hash then config.context
  else {}
  end
rescue StandardError
  {} # Broken proc? Swallow, never crash.
end
```

### 2C. Merge Order in `OpenTrace.log`

Update `log` to merge context into metadata with clear precedence:

```
base context (config.context) < auto-instrumentation metadata < explicit caller metadata
```

```ruby
def log(level, message, metadata = {})
  return unless enabled?
  return unless level_meets_threshold?(level)  # <-- early exit before any work

  # 1. Start with user-defined context (lowest priority)
  meta = resolve_context.dup

  # 2. Merge caller-provided metadata (overrides context)
  meta.merge!(metadata) if metadata.is_a?(Hash)

  payload = {
    timestamp: Time.now.utc.strftime("%Y-%m-%dT%H:%M:%S.%6NZ"),
    level: level.to_s.upcase,
    service: config.service,
    environment: config.environment,
    message: message.to_s,
    metadata: meta.compact
  }
  # ... trace_id extraction, enqueue — unchanged
end
```

The level check runs **before** context resolution, JSON serialization, or queue work — so filtered logs cost essentially nothing.

This means:
- Context proc provides defaults (user_id, account_id, etc.)
- The Rails subscriber adds request_id, controller, action, etc. (overrides context if key collides)
- Explicit `OpenTrace.log("INFO", "msg", { user_id: 99 })` wins over everything

### 2D. Remove `extract_user_id` from Rails Subscriber

Once `config.context` handles user_id injection globally, the `extract_user_id` hack in `rails.rb` becomes redundant. Remove:

```ruby
# DELETE these lines from forward_request_log:
user_id = extract_user_id(payload)
metadata[:user_id] = user_id if user_id

# DELETE the extract_user_id method entirely
```

The user sets `context = -> { { user_id: Current.user&.id } }` once, and it flows into every log — controllers, SQL, jobs, manual calls — automatically.

**Note:** If `config.context` is `nil` (default), no context is injected and the gem behaves exactly as before. This is a fully backward-compatible change.

### Phase 2 Tests

Add to `spec/opentrace_spec.rb`:

**Context tests:**

1. **Hash context merges into metadata** — Set `config.context = { tenant: "acme" }`, log a message, verify `tenant: "acme"` in metadata.
2. **Proc context is evaluated per call** — Set `config.context = -> { { ts: Time.now.to_i } }`, log twice, verify different timestamps.
3. **Caller metadata overrides context** — Set `config.context = { user_id: 1 }`, log with `metadata: { user_id: 99 }`, verify `user_id: 99`.
4. **Broken proc doesn't crash** — Set `config.context = -> { raise "boom" }`, verify log still succeeds with empty context.
5. **Nil context (default) works** — Don't set context, verify log works as before.
6. **Proc returning non-hash is ignored** — Set `config.context = -> { "bad" }`, verify no crash, empty context.

**Level filtering tests:**

7. **Default min_level is :debug (sends everything)** — Log at DEBUG, verify it's sent.
8. **min_level :warn filters out DEBUG and INFO** — Set `min_level = :warn`, log at DEBUG and INFO, verify neither is sent. Log at WARN, verify sent.
9. **min_level :error filters out WARN** — Set `min_level = :error`, log at WARN, verify not sent. Log at ERROR, verify sent.
10. **min_level accepts strings and symbols** — Set `min_level = "info"`, verify it works the same as `:info`.
11. **Filtered logs skip all work** — Set `min_level = :error`, log at DEBUG, verify no queue activity (nothing enqueued).

Update `spec/integration/rails_spec.rb`:

12. **Remove `extract_user_id` tests** — Replace with context-based user_id test: set `config.context = -> { { user_id: 42 } }`, instrument a request, verify `user_id: 42` in metadata.
13. **min_level filters Rails subscriber logs** — Set `min_level = :error`, instrument a 200 OK request (INFO level), verify NOT sent. Instrument a 500 request (ERROR level), verify sent.

---

## Phase 3: Static Context (Host/PID/Git SHA)

**Files modified:** `lib/opentrace/config.rb`, `lib/opentrace.rb`
**Risk:** Very low — additive config fields, no behavior change.

### 3A. New Config Fields

Add optional attributes to `Config`:

```ruby
attr_accessor :hostname, :pid, :git_sha

def initialize
  # ... existing fields ...
  @hostname = nil
  @pid      = nil
  @git_sha  = nil
end
```

### 3B. Auto-Populate Defaults

In `OpenTrace.log`, merge static context into metadata after resolving user context:

```ruby
def log(level, message, metadata = {})
  return unless enabled?

  # 1. User-defined context (lowest priority)
  meta = resolve_context.dup

  # 2. Caller-provided metadata
  meta.merge!(metadata) if metadata.is_a?(Hash)

  # 3. Static context — only fills in keys not already set
  static_context.each { |k, v| meta[k] ||= v }

  payload = { ... }
end

private

def static_context
  @static_context ||= {
    hostname: config.hostname || Socket.gethostname,
    pid: config.pid || Process.pid,
    git_sha: config.git_sha || ENV["REVISION"] || ENV["GIT_SHA"] || ENV["HEROKU_SLUG_COMMIT"]
  }.compact
end
```

Merge precedence (highest wins):
1. Explicit caller metadata
2. `config.context` (proc/hash)
3. Static context (hostname, pid, git_sha)

This is computed once and cached. Users can override via config or env vars.

### Phase 3 Tests

Add to `spec/opentrace_spec.rb`:

1. **Auto-populates hostname and pid** — Log a message, verify metadata contains `hostname` and `pid`.
2. **Respects config overrides** — Set `config.hostname = "web-3"`, verify it uses the override.
3. **Picks up env vars for git_sha** — Set `ENV["REVISION"]`, verify it appears in metadata.
4. **User metadata takes precedence** — Log with `metadata: { hostname: "custom" }`, verify "custom" wins.
5. **Static context is cached** — Verify `Socket.gethostname` is only called once across multiple logs.

---

## Phase 4: SQL Query Subscriber

**Files modified:** `lib/opentrace/rails.rb`
**Risk:** Medium — new subscription, potential for high volume. Needs threshold gating.

### 4A. New Config Fields

Add to `Config`:

```ruby
attr_accessor :sql_logging, :sql_duration_threshold_ms

def initialize
  # ... existing ...
  @sql_logging = true                # enable/disable SQL logging
  @sql_duration_threshold_ms = 0.0   # log all queries by default (0 = all)
end
```

### 4B. Subscribe to `sql.active_record`

In the Railtie `after_initialize` block, add a second subscription:

```ruby
if OpenTrace.config.sql_logging
  ActiveSupport::Notifications.subscribe("sql.active_record") do |*args|
    event = ActiveSupport::Notifications::Event.new(*args)
    forward_sql_log(event)
  rescue StandardError
    # Swallow
  end
end
```

### 4C. `forward_sql_log` Implementation

```ruby
def forward_sql_log(event)
  return unless OpenTrace.enabled?

  payload = event.payload
  duration = event.duration&.round(2)
  threshold = OpenTrace.config.sql_duration_threshold_ms

  # Skip if below threshold
  return if threshold > 0 && duration && duration < threshold

  # Skip SCHEMA queries (migrations, structure dumps)
  return if payload[:name] == "SCHEMA"

  metadata = {
    sql_name:       payload[:name],          # e.g. "User Load", "Order Create"
    sql:            truncate(payload[:sql], 1000),
    sql_duration_ms: duration,
    sql_cached:     payload[:cached] || false
  }.compact

  # Extract table name from SQL for easier filtering
  if payload[:sql] =~ /\b(?:FROM|INTO|UPDATE|JOIN)\s+[`"]?(\w+)[`"]?/i
    metadata[:sql_table] = $1
  end

  level = (duration && duration > 1000) ? "WARN" : "DEBUG"
  message = "SQL #{payload[:name]} #{duration}ms"

  OpenTrace.log(level, message, metadata)
rescue StandardError
  # Swallow
end
```

**Key design decisions:**
- Logs at `DEBUG` level by default, `WARN` for queries > 1 second
- Configurable threshold so users can set `sql_duration_threshold_ms = 100` to only capture slow queries
- Table name extracted via regex for the AI to correlate with `db_search`
- SQL truncated to 1000 chars to stay within payload limits
- `SCHEMA` queries skipped (migrations, internal Rails housekeeping)
- `sql_cached` included so the AI knows if it was a cache hit

### Phase 4 Tests

Add `spec/integration/sql_subscriber_spec.rb`:

1. **Captures SQL queries** — Instrument `sql.active_record` with sample payload, verify log sent with `sql_name`, `sql`, `sql_duration_ms`.
2. **Respects duration threshold** — Set threshold to 100ms, instrument a 50ms query, verify NOT logged. Instrument a 150ms query, verify logged.
3. **Skips SCHEMA queries** — Instrument with `name: "SCHEMA"`, verify NOT logged.
4. **Extracts table name** — Instrument with `sql: "SELECT * FROM users WHERE id = 1"`, verify `sql_table: "users"`.
5. **Truncates long SQL** — Instrument with 2000-char SQL, verify truncated to ~1000 chars.
6. **Logs slow queries as WARN** — Instrument with duration > 1000ms, verify level is `WARN`.
7. **Disabled via config** — Set `sql_logging = false`, verify no subscription created.
8. **Swallows errors** — Instrument with payload that causes an error in processing, verify no exception raised.

### Update `ActiveSupport::Notifications` Stub

The test stub in `spec/integration/rails_spec.rb` currently only supports one subscriber per event name (uses a hash). Update to support an array of subscribers:

```ruby
# Change @subscribers to store arrays
@subscribers = Hash.new { |h, k| h[k] = [] }

def self.subscribe(event_name, &block)
  @subscribers[event_name] << block
end

def self.instrument(event_name, payload = {})
  start_time = Time.now
  result = yield if block_given?
  end_time = Time.now

  @subscribers[event_name].each do |subscriber|
    subscriber.call(event_name, start_time, end_time, SecureRandom.hex(4), payload)
  end

  result
end
```

---

## Phase 5: Active Job Subscriber

**Files modified:** `lib/opentrace/rails.rb`
**Risk:** Low — same pattern as SQL, lower volume.

### 5A. Subscribe to `perform.active_job`

In the Railtie `after_initialize` block:

```ruby
ActiveSupport::Notifications.subscribe("perform.active_job") do |*args|
  event = ActiveSupport::Notifications::Event.new(*args)
  forward_job_log(event)
rescue StandardError
  # Swallow
end
```

### 5B. `forward_job_log` Implementation

```ruby
def forward_job_log(event)
  return unless OpenTrace.enabled?

  payload = event.payload
  job = payload[:job]

  metadata = {
    job_class:   job.class.name,
    job_id:      job.job_id,
    queue_name:  job.queue_name,
    executions:  job.executions,          # retry count
    duration_ms: event.duration&.round(1)
  }.compact

  # Capture arguments (filtered, truncated)
  if job.respond_to?(:arguments)
    args_json = JSON.generate(job.arguments)
    metadata[:job_arguments] = if args_json.bytesize > 512
                                  args_json[0, 512] + "..."
                                else
                                  job.arguments
                                end
  end

  # Capture exceptions from job failures
  if payload[:exception_object]
    metadata[:exception_class]   = payload[:exception_object].class.name
    metadata[:exception_message] = truncate(payload[:exception_object].message, 500)
    if payload[:exception_object].backtrace
      metadata[:backtrace] = clean_backtrace(payload[:exception_object].backtrace).first(15)
    end
  end

  level = payload[:exception_object] ? "ERROR" : "INFO"
  message = if payload[:exception_object]
              "Job #{job.class.name} FAILED (attempt #{job.executions})"
            else
              "Job #{job.class.name} completed #{event.duration&.round(1)}ms"
            end

  OpenTrace.log(level, message, metadata)
rescue StandardError
  # Swallow
end
```

### Phase 5 Tests

Add `spec/integration/job_subscriber_spec.rb`:

1. **Captures successful job** — Instrument with job stub, verify `job_class`, `job_id`, `queue_name`, `duration_ms`.
2. **Captures failed job** — Instrument with `exception_object`, verify `exception_class`, `exception_message`, `backtrace`, and level `ERROR`.
3. **Includes retry count** — Set `executions: 3`, verify `executions: 3` in metadata.
4. **Truncates large arguments** — Pass arguments > 512 bytes, verify truncated.
5. **Swallows errors** — Verify no exceptions leak.

---

## Phase 6: Payload Safety — Smart Truncation

**Files modified:** `lib/opentrace/client.rb`
**Risk:** Low — only affects payloads that would have been silently dropped anyway (> 32KB).

### Current Behavior (Problem)

```ruby
# client.rb:70
return if json.bytesize > PAYLOAD_MAX_BYTES
```

If a payload exceeds 32KB, it's silently **dropped entirely**. With richer metadata, this will happen more often.

### Proposed: Truncate Instead of Drop

```ruby
def send_payload(uri, payload)
  json = JSON.generate(payload)

  if json.bytesize > PAYLOAD_MAX_BYTES
    payload = truncate_payload(payload)
    json = JSON.generate(payload)
    # If still too large after truncation, drop it
    return if json.bytesize > PAYLOAD_MAX_BYTES
  end

  # ... rest unchanged
end

def truncate_payload(payload)
  meta = payload[:metadata]&.dup || {}

  # Truncation priority: remove largest optional fields first
  meta.delete(:backtrace)     if meta[:backtrace]
  meta.delete(:params)        if meta[:params]
  meta[:sql] = meta[:sql][0, 200] + "..." if meta[:sql]&.length.to_i > 200
  meta[:exception_message] = meta[:exception_message][0, 200] + "..." if meta[:exception_message]&.length.to_i > 200

  payload.merge(metadata: meta)
end
```

### Phase 6 Tests

Add to `spec/opentrace/client_spec.rb`:

1. **Large payload gets truncated, not dropped** — Build a payload > 32KB with a huge backtrace, verify the HTTP request is still made (with truncated backtrace removed).
2. **Normal payloads pass through unchanged** — Verify no truncation on payloads under 32KB.
3. **Truly massive payloads still dropped** — Build a payload that's still > 32KB after truncation (e.g., 30KB message), verify it's dropped.

---

## Phase 7: Batch Sending

**Files modified:** `lib/opentrace/config.rb`, `lib/opentrace/client.rb`
**Risk:** Medium — changes the core dispatch loop, but the "never crash" guarantees remain intact.

### Problem

Currently every `OpenTrace.log` call results in 1 HTTP POST. With SQL logging enabled (Phase 4), a single page load could generate 10-50 SQL logs + 1 request log = 11-51 HTTP requests to the OpenTrace server. At scale, this is:
- Wasteful — the server already accepts arrays via `POST /api/logs`
- Slow — each HTTP round-trip takes ~1-5ms of the background thread's time
- Risky — could overwhelm the server on high-traffic apps

### Solution: Batch Queue Drain + Flush Timer

Instead of popping one payload at a time, the dispatch loop drains the queue into a batch and sends them as a JSON array.

### 7A. Config Changes

```ruby
attr_accessor :batch_size, :flush_interval

def initialize
  # ... existing ...
  @batch_size     = 50    # max logs per HTTP request
  @flush_interval = 5.0   # seconds — flush even if batch isn't full
end
```

### 7B. Updated `dispatch_loop` in Client

```ruby
def dispatch_loop
  uri = URI.join(@config.endpoint.chomp("/") + "/", "api/logs")

  loop do
    batch = drain_queue

    break if batch.nil?  # queue closed, no more items
    next if batch.empty?

    send_batch(uri, batch)
  end
rescue Exception # rubocop:disable Lint/RescueException
  # Swallow all errors including thread kill
end

def drain_queue
  batch = []
  deadline = Time.now + @config.flush_interval

  loop do
    timeout = [deadline - Time.now, 0].max

    # Wait for first item (blocks up to flush_interval)
    # After first item, drain remaining without blocking
    if batch.empty?
      item = pop_with_timeout(timeout)
      return nil if item.nil? && @queue.closed?
      batch << item if item
    else
      # Non-blocking drain up to batch_size
      while batch.size < @config.batch_size
        begin
          item = @queue.pop(true) # non_block = true
          batch << item
        rescue ThreadError
          break # queue empty
        end
      end
    end

    # Flush if batch is full or deadline reached
    break if batch.size >= @config.batch_size
    break if Time.now >= deadline && !batch.empty?
    break if @queue.closed?
  end

  batch
end

def pop_with_timeout(timeout)
  # Ruby's Thread::Queue doesn't have native timeout.
  # Use a simple poll loop with short sleeps.
  deadline = Time.now + timeout
  loop do
    begin
      return @queue.pop(true)
    rescue ThreadError
      return nil if Time.now >= deadline || @queue.closed?
      sleep(0.05) # 50ms poll interval
    end
  end
rescue ClosedQueueError
  nil
end
```

### 7C. `send_batch` Method

```ruby
def send_batch(uri, batch)
  # Apply per-payload truncation
  batch = batch.map { |p| fit_payload(p) }.compact

  return if batch.empty?

  json = JSON.generate(batch)

  # If entire batch exceeds limit, split and retry
  if json.bytesize > PAYLOAD_MAX_BYTES
    mid = batch.size / 2
    send_batch(uri, batch[0...mid]) if mid > 0
    send_batch(uri, batch[mid..])   if mid < batch.size
    return
  end

  http = build_http(uri)
  request = Net::HTTP::Post.new(uri.request_uri)
  request["Authorization"] = "Bearer #{@config.api_key}"
  request["Content-Type"]  = "application/json"
  request["User-Agent"]    = "opentrace-ruby/#{OpenTrace::VERSION}"
  request.body = json

  http.request(request)
rescue StandardError
  # Swallow all network errors silently
end

def build_http(uri)
  http = Net::HTTP.new(uri.host, uri.port)
  http.use_ssl = (uri.scheme == "https")
  http.open_timeout = @config.timeout
  http.read_timeout = @config.timeout
  http.write_timeout = @config.timeout
  http
end

def fit_payload(payload)
  json = JSON.generate(payload)
  if json.bytesize > PAYLOAD_MAX_BYTES
    payload = truncate_payload(payload)
    json = JSON.generate(payload)
    return nil if json.bytesize > PAYLOAD_MAX_BYTES
  end
  payload
rescue StandardError
  nil
end
```

**Key design decisions:**
- **Batch size default 50** — keeps each HTTP body well under 32KB for typical logs (~500 bytes each)
- **Flush interval 5s** — ensures low-traffic apps don't accumulate stale logs; logs arrive within 5s worst case
- **Recursive split** — if a batch exceeds 32KB (e.g., several logs with large backtraces), it splits in half and retries, guaranteeing delivery of whatever fits
- **Server compatibility** — the OpenTrace server already accepts JSON arrays on `POST /api/logs`, so no backend changes needed
- **Graceful shutdown** — `shutdown` closes the queue, `drain_queue` detects the close, flushes remaining items, and exits

### 7D. Update `shutdown` for Batch Flush

```ruby
def shutdown(timeout: 5)
  @queue.close           # signals dispatch_loop to drain and exit
  @thread&.join(timeout) # wait for final batch to send
end
```

No change needed — the existing `shutdown` already works because `drain_queue` detects `@queue.closed?` and returns the remaining batch before returning `nil`.

### Phase 7 Tests

Add to `spec/opentrace/client_spec.rb`:

1. **Sends as JSON array** — Enqueue 3 payloads, wait for flush, verify the HTTP body is a JSON array of 3 items.
2. **Flushes at batch_size** — Set `batch_size = 2`, enqueue 2 payloads, verify they're sent together without waiting for flush_interval.
3. **Flushes at interval** — Set `flush_interval = 0.5`, enqueue 1 payload, verify it's sent within ~0.5s even though batch_size isn't reached.
4. **Large batch splits** — Enqueue several payloads that together exceed 32KB, verify multiple HTTP requests are made.
5. **Shutdown flushes remaining** — Enqueue 3 payloads, immediately call shutdown, verify all 3 are sent.
6. **Empty queue doesn't send** — Start client with nothing enqueued, verify no HTTP requests.
7. **Backward compatible defaults** — Verify default batch_size=50 and flush_interval=5.

---

## Phase 8: Request ID Propagation via Middleware

**Files modified:** `lib/opentrace/middleware.rb` (new), `lib/opentrace/rails.rb`, `lib/opentrace.rb`
**Risk:** Low — opt-in middleware, reads an existing header, no side effects.

### Problem

The Rails subscriber captures `request_id` for controller logs, but:
- SQL logs fired during the same request have no `request_id`
- Manual `OpenTrace.log()` calls within a controller action have no `request_id`
- The AI cannot group "all logs from this request" together

### Solution: Rack Middleware + Thread-Local `request_id`

A thin middleware reads `action_dispatch.request_id` (or `X-Request-Id` header) and stores it in a thread-local. The `OpenTrace.log` method picks it up automatically — every log within the request gets the same `request_id` without the user writing any code.

### 8A. New File: `lib/opentrace/middleware.rb`

```ruby
# frozen_string_literal: true

module OpenTrace
  class Middleware
    def initialize(app)
      @app = app
    end

    def call(env)
      # Read request_id from Rails or X-Request-Id header
      request_id = env["action_dispatch.request_id"] || env["HTTP_X_REQUEST_ID"]
      OpenTrace.current_request_id = request_id

      @app.call(env)
    ensure
      OpenTrace.current_request_id = nil  # always clean up
    end
  end
end
```

### 8B. Thread-Local Accessors in `OpenTrace` Module

Add to `lib/opentrace.rb`:

```ruby
def current_request_id
  Thread.current[:opentrace_request_id]
end

def current_request_id=(id)
  Thread.current[:opentrace_request_id] = id
end
```

### 8C. Merge `request_id` in `OpenTrace.log`

In the `log` method, after merging context and static context:

```ruby
# 4. Request ID from middleware (if not already set by caller or context)
meta[:request_id] ||= current_request_id if current_request_id
```

This means:
- The middleware sets it automatically per-request
- SQL logs, job logs, manual logs — all get `request_id` for free
- The existing `forward_request_log` still sets `request_id` from the event payload, which takes precedence (it's in the caller metadata)
- Non-Rails apps can use the middleware directly in their Rack stack

### 8D. Auto-Insert Middleware in Railtie

In `lib/opentrace/rails.rb`, inside the `after_initialize` block:

```ruby
# Insert middleware early in the stack so request_id is available for all logs
app.middleware.insert_after ActionDispatch::RequestId, OpenTrace::Middleware
```

This runs after Rails' own `RequestId` middleware, so `action_dispatch.request_id` is already set.

**Fallback for non-Rails apps:**

```ruby
# Sinatra
use OpenTrace::Middleware

# Any Rack app
app = Rack::Builder.new do
  use OpenTrace::Middleware
  run MyApp
end
```

### 8E. Remove Redundant `request_id` from Rails Subscriber

The `forward_request_log` method currently extracts `request_id` from `payload[:headers]`. Since the middleware now provides it globally, this line becomes redundant for the common case — but we keep it as a fallback in case someone doesn't use the middleware:

```ruby
# Keep this line — it overrides the thread-local with the event's authoritative value
request_id: payload[:headers]&.env&.dig("action_dispatch.request_id"),
```

No change needed here — the existing code provides the correct override.

### Phase 8 Tests

Add `spec/opentrace/middleware_spec.rb`:

1. **Sets request_id from action_dispatch** — Simulate a Rack env with `action_dispatch.request_id`, verify `OpenTrace.current_request_id` is set during the request.
2. **Sets request_id from X-Request-Id header** — Simulate env with `HTTP_X_REQUEST_ID`, verify it's used as fallback.
3. **Cleans up after request** — Verify `current_request_id` is nil after the middleware completes.
4. **Cleans up on exception** — Raise inside the app, verify `current_request_id` is still nil after.
5. **request_id appears in logs** — Set request_id via middleware, call `OpenTrace.log`, verify `request_id` in metadata.
6. **SQL logs get request_id** — Set request_id, instrument `sql.active_record`, verify the SQL log includes `request_id`.
7. **Explicit request_id overrides middleware** — Log with `metadata: { request_id: "custom" }`, verify "custom" wins.

Add to `spec/integration/rails_spec.rb`:

8. **Middleware auto-inserted** — Verify `OpenTrace::Middleware` is in the middleware stack after initialization.

---

## Phase 9: `OpenTrace.error` Convenience Method

**Files modified:** `lib/opentrace.rb`
**Risk:** Very low — pure sugar, delegates to existing `log` method.

### Problem

Logging exceptions manually is verbose:

```ruby
begin
  process_order(order)
rescue => e
  OpenTrace.log("ERROR", e.message, {
    exception_class: e.class.name,
    exception_message: e.message,
    backtrace: e.backtrace&.first(15),
    order_id: order.id
  })
  raise
end
```

### Solution: `OpenTrace.error(exception, metadata = {})`

```ruby
# Same result in one line:
rescue => e
  OpenTrace.error(e, { order_id: order.id })
  raise
end
```

### 9A. Implementation

Add to `OpenTrace` module (public API):

```ruby
def error(exception, metadata = {})
  return unless enabled?

  meta = metadata.is_a?(Hash) ? metadata.dup : {}
  meta[:exception_class]   = exception.class.name
  meta[:exception_message] = exception.message&.slice(0, 500)

  if exception.backtrace
    cleaned = if defined?(::Rails) && ::Rails.respond_to?(:backtrace_cleaner)
                ::Rails.backtrace_cleaner.clean(exception.backtrace)
              else
                exception.backtrace.reject { |l| l.include?("/gems/") }
              end
    meta[:backtrace] = cleaned.first(15)
  end

  log("ERROR", exception.message.to_s, meta)
rescue StandardError
  # Never raise to the host app
end
```

**Key design decisions:**
- Delegates to `log` — inherits context injection, level filtering, static context, request_id, batching — everything
- Backtrace cleaned the same way as the Rails subscriber (DRY)
- Message truncated to 500 chars (same as Phase 1)
- Returns nil — consistent with "never affect the host app"
- Works outside Rails (falls back to simple gem-path filtering)

### Phase 9 Tests

Add to `spec/opentrace_spec.rb`:

1. **Logs exception with class, message, backtrace** — Create a `RuntimeError`, call `OpenTrace.error(e)`, verify all three fields in metadata.
2. **Merges custom metadata** — Call `OpenTrace.error(e, { order_id: 123 })`, verify `order_id` appears alongside exception fields.
3. **Truncates long messages** — Create an exception with a 1000-char message, verify it's truncated to 500.
4. **Handles exception without backtrace** — Call `OpenTrace.error(RuntimeError.new("no bt"))` (no raise = no backtrace), verify no crash.
5. **Respects min_level** — Set `min_level = :fatal`, call `OpenTrace.error(e)`, verify NOT sent (ERROR < FATAL).
6. **Inherits context** — Set `config.context = { user_id: 42 }`, call `OpenTrace.error(e)`, verify `user_id` in metadata.
7. **Swallows internal errors** — Mock `log` to raise, verify `error` doesn't raise.

---

## Summary of All File Changes

| File | Changes |
|------|---------|
| `lib/opentrace/config.rb` | Add `context`, `min_level`, `hostname`, `pid`, `git_sha`, `sql_logging`, `sql_duration_threshold_ms`, `batch_size`, `flush_interval` attributes, add `LEVELS` constant and `min_level_value` method |
| `lib/opentrace.rb` | Add `level_meets_threshold?`, `resolve_context`, `static_context`, `current_request_id` accessors, `error` convenience method, merge context + host/pid/git_sha + request_id into every `log()` call, add `require "socket"` |
| `lib/opentrace/rails.rb` | Remove `extract_user_id`, extract exception + params from existing subscriber, add SQL + ActiveJob subscribers, auto-insert middleware, add helper methods (`truncate`, `clean_backtrace`, `truncate_hash`) |
| `lib/opentrace/middleware.rb` | **New file** — Rack middleware that sets `request_id` thread-local from `action_dispatch.request_id` or `X-Request-Id` header |
| `lib/opentrace/client.rb` | Rewrite dispatch loop for batch sending (`drain_queue`, `send_batch`, `fit_payload`), add `truncate_payload` for smart truncation |
| `spec/integration/rails_spec.rb` | Update `ActiveSupport::Notifications` stub to support multiple subscribers, replace `extract_user_id` tests with context-based tests, add exception/params/level tests, middleware auto-insert test |
| `spec/integration/sql_subscriber_spec.rb` | **New file** — SQL subscriber tests |
| `spec/integration/job_subscriber_spec.rb` | **New file** — ActiveJob subscriber tests |
| `spec/opentrace/middleware_spec.rb` | **New file** — Middleware tests (request_id propagation, cleanup, override) |
| `spec/opentrace_spec.rb` | Add user context, level filtering, static context, `error` method, and request_id tests |
| `spec/opentrace/client_spec.rb` | Add batch sending and payload truncation tests |

## Implementation Order

1. **Phase 1** — Exception + params + level logic (biggest value, smallest diff)
2. **Phase 2** — User context injection + level filtering (enables all subsequent phases to carry user identity)
3. **Phase 3** — Static context: host/pid/git_sha (trivial, no risk)
4. **Phase 6** — Payload truncation (safety net needed before phases 4/5 add more data)
5. **Phase 7** — Batch sending (must land before SQL logging, which generates high volume)
6. **Phase 8** — Request ID propagation middleware (needed so SQL/job logs carry request_id)
7. **Phase 4** — SQL subscriber (now safe: batching reduces HTTP calls, request_id ties SQL to requests)
8. **Phase 5** — ActiveJob subscriber
9. **Phase 9** — `OpenTrace.error` convenience method (pure sugar, no dependencies)

## Example Final Payload

After all phases, a typical error log:

```json
{
  "timestamp": "2026-02-09T14:30:45.123456Z",
  "level": "ERROR",
  "service": "billing-api",
  "environment": "production",
  "trace_id": "abc-123",
  "message": "POST /api/orders 422 245.3ms",
  "metadata": {
    "request_id": "req-456",
    "controller": "OrdersController",
    "action": "create",
    "method": "POST",
    "path": "/api/orders",
    "status": 422,
    "duration_ms": 245.3,
    "user_id": 42,
    "account_id": 7,
    "session_id": "sess_abc123",
    "params": { "order": { "product_id": 99, "quantity": 2 } },
    "exception_class": "ActiveRecord::RecordNotUnique",
    "exception_message": "PG::UniqueViolation: duplicate key value violates unique constraint...",
    "backtrace": [
      "app/models/order.rb:34:in `create_line_item'",
      "app/controllers/orders_controller.rb:18:in `create'"
    ],
    "hostname": "web-3",
    "pid": 12345,
    "git_sha": "a1b2c3d"
  }
}
```

A correlated SQL log entry (same `request_id` — the AI can group them):

```json
{
  "timestamp": "2026-02-09T14:30:45.120234Z",
  "level": "DEBUG",
  "service": "billing-api",
  "environment": "production",
  "message": "SQL LineItem Create 3.2ms",
  "metadata": {
    "request_id": "req-456",
    "user_id": 42,
    "account_id": 7,
    "sql_name": "LineItem Create",
    "sql": "INSERT INTO line_items (order_id, product_id) VALUES ($1, $2)",
    "sql_duration_ms": 3.2,
    "sql_table": "line_items",
    "sql_cached": false,
    "hostname": "web-3",
    "pid": 12345,
    "git_sha": "a1b2c3d"
  }
}
```

A failed background job:

```json
{
  "timestamp": "2026-02-09T14:35:12.456789Z",
  "level": "ERROR",
  "service": "billing-api",
  "environment": "production",
  "message": "Job OrderConfirmationJob FAILED (attempt 2)",
  "metadata": {
    "job_class": "OrderConfirmationJob",
    "job_id": "job-789",
    "queue_name": "default",
    "executions": 2,
    "duration_ms": 134.5,
    "job_arguments": [42],
    "exception_class": "Net::SMTPServerBusy",
    "exception_message": "452 Too many recipients",
    "backtrace": [
      "app/jobs/order_confirmation_job.rb:12:in `perform'"
    ],
    "user_id": 42,
    "account_id": 7,
    "hostname": "worker-1",
    "pid": 23456,
    "git_sha": "a1b2c3d"
  }
}
```

Manual error logging via `OpenTrace.error`:

```ruby
rescue => e
  OpenTrace.error(e, { order_id: order.id })
  raise
end
```

```json
{
  "timestamp": "2026-02-09T14:30:45.200000Z",
  "level": "ERROR",
  "service": "billing-api",
  "environment": "production",
  "message": "PG::UniqueViolation: duplicate key value violates unique constraint",
  "metadata": {
    "request_id": "req-456",
    "user_id": 42,
    "account_id": 7,
    "order_id": 123,
    "exception_class": "ActiveRecord::RecordNotUnique",
    "exception_message": "PG::UniqueViolation: duplicate key value violates unique constraint...",
    "backtrace": [
      "app/models/order.rb:34:in `create_line_item'",
      "app/controllers/orders_controller.rb:18:in `create'"
    ],
    "hostname": "web-3",
    "pid": 12345,
    "git_sha": "a1b2c3d"
  }
}
```
