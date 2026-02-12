# OpenTrace Ruby Gem — Enhanced Observability Implementation Plan

> **Goal**: Make OpenTrace the best data source for Claude Code to debug production Rails apps.
> **Constraint**: Never crash, never slow down the host app. All features must be safe by default.
> **Current version**: v0.3.0

---

## Table of Contents

- [Architecture Overview](#architecture-overview)
- [Phase 1: Zero-Cost Additions (v0.4.0)](#phase-1-zero-cost-additions-v040)
  - [1.1 N+1 Query Counter](#11-n1-query-counter)
  - [1.2 Request Headers](#12-request-headers)
  - [1.3 Job Queue Latency](#13-job-queue-latency)
  - [1.4 Deprecation Warnings](#14-deprecation-warnings)
  - [1.5 Error Fingerprinting](#15-error-fingerprinting)
  - [1.6 DB Connection Pool Stats](#16-db-connection-pool-stats)
  - [1.7 Job Queue Depth](#17-job-queue-depth)
- [Phase 2: Accumulate-and-Summarize Architecture (v0.5.0)](#phase-2-accumulate-and-summarize-architecture-v050)
  - [2.1 RequestCollector](#21-requestcollector)
  - [2.2 View Render Tracking](#22-view-render-tracking)
  - [2.3 Cache Operation Tracking](#23-cache-operation-tracking)
  - [2.4 Per-Request Summary](#24-per-request-summary)
  - [2.5 Request Timeline](#25-request-timeline)
- [Phase 3: Opt-In Advanced Features (v0.6.0)](#phase-3-opt-in-advanced-features-v060)
  - [3.1 Memory Delta Tracking](#31-memory-delta-tracking)
  - [3.2 External HTTP Tracking](#32-external-http-tracking)
- [Config Reference](#config-reference)
- [Migration Guide](#migration-guide)
- [File Changes Summary](#file-changes-summary)
- [Test Plan](#test-plan)

---

## Architecture Overview

### Current Architecture (v0.3.0)

```
Request Thread                          Background Thread
─────────────────                       ─────────────────
Middleware sets Fiber[:request_id]
     │
     ▼
Controller runs
     │
     ▼
AS::Notifications fires ──► Subscriber builds hash ──► queue.push(payload)
     │                                                        │
     ▼                                                        ▼
SQL notification fires ──► Subscriber builds hash ──► queue.push(payload)
SQL notification fires ──► Subscriber builds hash ──► queue.push(payload)
SQL notification fires ──► Subscriber builds hash ──► queue.push(payload)
     │                                                        │
     ▼                                                        ▼
Job notification fires ──► Subscriber builds hash ──► queue.push(payload)
     │                                               drain_queue collects batch
     ▼                                                        │
Middleware clears Fiber[:request_id]                   HTTP POST /api/logs
```

**Problem**: Each event = 1 queue push. With new subscribers (views, cache, HTTP), a single
request could produce 200+ queue pushes, overwhelming the bounded queue (1000).

### Target Architecture (v0.5.0+)

```
Request Thread                          Background Thread
─────────────────                       ─────────────────
Middleware creates RequestCollector
Middleware snapshots memory (if opt-in)
     │
     ▼
Controller runs
     │
     ▼
SQL notification ──► collector.record_sql()      (array append, ~20ns)
SQL notification ──► collector.record_sql()      (array append, ~20ns)
View notification ──► collector.record_view()    (array append, ~20ns)
Cache notification ──► collector.record_cache()  (array append, ~20ns)
HTTP notification ──► collector.record_http()    (array append, ~20ns)
     │
     ▼
Controller finishes
     │
     ▼
process_action subscriber ──► collector.build_summary() ──► queue.push(ONE payload)
     │                                                            │
     ▼                                                            ▼
Middleware clears collector                                drain_queue collects batch
Middleware snapshots memory delta (if opt-in)                      │
                                                           HTTP POST /api/logs
```

**Result**: 1 queue push per request regardless of how many SQL/view/cache events fired.

---

## Phase 1: Zero-Cost Additions (v0.4.0)

These features piggyback on existing code paths or run outside the request thread.
No architectural changes needed. Ship as a minor version bump.

**All Phase 1 features are always-on (except pool/queue monitoring which are opt-in)
because their overhead is negligible.**

---

### 1.1 N+1 Query Counter

**What it does**: Counts SQL queries per request in the existing SQL subscriber. Adds
`sql_query_count` and `sql_total_ms` to the controller request log. Flags requests
with more than 20 queries via `n_plus_one_warning: true`.

**Why Claude needs it**: When investigating slow requests, Claude currently sees
"GET /dashboard 200 2400ms" but can't tell if the slowness is from 2 heavy queries or
200 tiny ones. The count immediately reveals N+1 patterns without Claude needing to
search through individual SQL logs.

**Implementation**:

File: `lib/opentrace/middleware.rb` — initialize counters

```ruby
def call(env)
  request_id = env["action_dispatch.request_id"] || env["HTTP_X_REQUEST_ID"]
  OpenTrace.current_request_id = request_id
  Fiber[:opentrace_sql_count] = 0
  Fiber[:opentrace_sql_total_ms] = 0.0

  @app.call(env)
ensure
  OpenTrace.current_request_id = nil
  Fiber[:opentrace_sql_count] = nil
  Fiber[:opentrace_sql_total_ms] = nil
end
```

File: `lib/opentrace/rails.rb` — increment in existing SQL subscriber

```ruby
ActiveSupport::Notifications.subscribe("sql.active_record") do |*args|
  event = ActiveSupport::Notifications::Event.new(*args)

  # Increment per-request SQL counter (Fiber-local, zero-cost)
  if Fiber[:opentrace_sql_count]
    Fiber[:opentrace_sql_count] += 1
    Fiber[:opentrace_sql_total_ms] = (Fiber[:opentrace_sql_total_ms] || 0.0) + (event.duration || 0.0)
  end

  forward_sql_log(event)
rescue StandardError
  # Swallow
end
```

File: `lib/opentrace/rails.rb` — add to `forward_request_log` metadata

```ruby
metadata[:sql_query_count] = Fiber[:opentrace_sql_count] if Fiber[:opentrace_sql_count]
metadata[:sql_total_ms] = Fiber[:opentrace_sql_total_ms]&.round(1) if Fiber[:opentrace_sql_total_ms]

if Fiber[:opentrace_sql_count].to_i > 20
  metadata[:n_plus_one_warning] = true
end
```

**Example payload (added to existing controller log)**:

```json
{
  "level": "INFO",
  "message": "GET /dashboard 200 2400ms",
  "metadata": {
    "controller": "DashboardController",
    "action": "index",
    "status": 200,
    "duration_ms": 2400.0,
    "sql_query_count": 47,
    "sql_total_ms": 823.4,
    "n_plus_one_warning": true,
    "request_id": "req-abc123"
  }
}
```

**How Claude uses it**:

```
User: "The dashboard is slow in production"

Claude searches OpenTrace: level=INFO, controller=DashboardController, action=index
Claude sees: sql_query_count=47, n_plus_one_warning=true, sql_total_ms=823ms
Claude reads app/controllers/dashboard_controller.rb → finds @users = User.all
Claude reads app/views/dashboard/index.html.erb → finds user.orders.count in a loop
Claude suggests: User.all.includes(:orders) or add counter_cache on the association
```

**Side effects**: One integer increment (`+=1`) and one float addition (`+=`) per SQL query
in Fiber-local storage. These operations take ~2ns each. Even with 500 SQL queries per
request, total overhead is ~1μs. Two Fiber-local variables initialized and cleaned up per
request.

**Risks**: None. Fiber-local storage is request-scoped and automatically cleaned up in the
`ensure` block. If the middleware isn't present (non-Rails), the `if Fiber[:opentrace_sql_count]`
guard skips the increment entirely.

---

### 1.2 Request Headers

**What it does**: Captures a curated set of request headers in the existing controller
subscriber. Not all headers — only the ones useful for debugging: `Content-Type`, `Accept`,
`User-Agent`, `Referer`.

**Why Claude needs it**: Headers reveal client behavior invisible in status codes. A 415 error
means nothing until Claude can see the client sent `Content-Type: text/plain` to a JSON
endpoint. A 406 makes sense when Claude sees `Accept: application/xml` on a JSON-only API.
User-Agent distinguishes browser vs API client vs webhook sender.

**Implementation**:

File: `lib/opentrace/rails.rb` — new helper method + call in `forward_request_log`

```ruby
def extract_request_headers(payload, metadata)
  return unless payload[:headers]&.respond_to?(:env)

  env = payload[:headers].env
  headers = {
    request_content_type: env["CONTENT_TYPE"],
    request_accept: env["HTTP_ACCEPT"],
    request_user_agent: truncate(env["HTTP_USER_AGENT"], 200),
    request_referer: env["HTTP_REFERER"]
  }.compact
  metadata.merge!(headers) unless headers.empty?
rescue StandardError
  # Swallow
end
```

In `forward_request_log`, after existing metadata building:

```ruby
extract_request_headers(payload, metadata)
```

**Example payload (added to existing controller log)**:

```json
{
  "level": "WARN",
  "message": "POST /api/v2/webhooks 415 0.8ms",
  "metadata": {
    "controller": "Api::V2::WebhooksController",
    "action": "create",
    "status": 415,
    "request_content_type": "application/x-www-form-urlencoded",
    "request_accept": "*/*",
    "request_user_agent": "ShopifyWebhooks/1.0"
  }
}
```

**How Claude uses it**:

```
User: "Shopify webhooks stopped working, we're getting 415 errors"

Claude searches OpenTrace: controller=Api::V2::WebhooksController, status=415
Claude sees: request_content_type="application/x-www-form-urlencoded"
Claude reads the controller → finds before_action :verify_json_content_type
Claude explains: Shopify changed webhook content type. Update controller to accept both.
```

**Side effects**: 4 hash reads from the Rack env hash (already in memory). ~50ns total.
User-Agent truncated to 200 chars to prevent oversized payloads.

**Risks**: None. The env hash is already available in the payload. We're reading 4 string
values from it. The `respond_to?(:env)` guard prevents crashes if the headers object is
unexpected.

---

### 1.3 Job Queue Latency

**What it does**: Calculates time a job spent waiting in the queue before execution started.
Uses `job.enqueued_at` which ActiveJob already provides. Adds `queue_latency_ms` and
`enqueued_at` to existing job logs.

**Why Claude needs it**: Job execution time can be 200ms but if the job waited 45 seconds in
the queue, the user experiences a 45-second delay. Without queue latency, Claude sees
"job completed in 200ms" and concludes everything is fine — completely missing the real
problem.

**Implementation**:

File: `lib/opentrace/rails.rb` — add to `forward_job_log`, after existing metadata building

```ruby
# Queue latency calculation
if job.respond_to?(:enqueued_at) && job.enqueued_at
  enqueued_at = case job.enqueued_at
                when Time then job.enqueued_at
                when String then Time.parse(job.enqueued_at)
                end
  if enqueued_at
    queue_latency_s = Time.now.utc - enqueued_at.utc
    metadata[:queue_latency_ms] = (queue_latency_s * 1000).round(1) if queue_latency_s > 0
    metadata[:enqueued_at] = enqueued_at.utc.strftime("%Y-%m-%dT%H:%M:%S.%6NZ")
  end
end
```

**Example payload (added to existing job log)**:

```json
{
  "level": "INFO",
  "message": "Job OrderConfirmationMailer completed 234ms",
  "metadata": {
    "job_class": "OrderConfirmationMailer",
    "job_id": "job-xyz789",
    "queue_name": "mailers",
    "duration_ms": 234.5,
    "queue_latency_ms": 47200.0,
    "enqueued_at": "2026-02-12T10:00:00.000000Z",
    "executions": 1
  }
}
```

**How Claude uses it**:

```
User: "Customers say order confirmation emails take a minute to arrive"

Claude searches OpenTrace: job_class=OrderConfirmationMailer
Claude sees: duration_ms=234.5 (fast), queue_latency_ms=47200.0 (47 seconds waiting!)
Claude searches for other jobs on queue_name=mailers
Claude finds: BulkReportJob runs every 5 minutes, takes 45s, blocking the queue
Claude suggests: Move BulkReportJob to a separate "reports" queue
```

**Side effects**: One `Time.parse` (if enqueued_at is a string, ~1μs) and one time subtraction
(~10ns). Only runs once per job execution. No cost for web requests.

**Risks**: `job.enqueued_at` may return nil for manually instantiated jobs or older ActiveJob
versions. The `respond_to?` guard handles this. `Time.parse` is wrapped in the case statement
so it only runs on strings. No crash risk.

---

### 1.4 Deprecation Warnings

**What it does**: Subscribes to `deprecation.rails` notifications to capture Rails deprecation
warnings with their callsite location.

**Why Claude needs it**: Deprecations predict future breakage. When a user asks "we're upgrading
to Rails 8.1, what will break?", Claude needs runtime deprecation data — not just static
analysis — because metaprogramming, dynamic dispatch, and gem internals only show up at runtime.

**Implementation**:

File: `lib/opentrace/rails.rb` — new subscriber in `config.after_initialize`

```ruby
# Subscribe to deprecation warnings
ActiveSupport::Notifications.subscribe("deprecation.rails") do |*args|
  event = ActiveSupport::Notifications::Event.new(*args)
  forward_deprecation_log(event)
rescue StandardError
  # Swallow
end
```

New helper method:

```ruby
def forward_deprecation_log(event)
  return unless OpenTrace.enabled?

  payload = event.payload
  message = payload[:message].to_s
  callsite = payload[:callstack]&.first&.to_s

  metadata = {
    deprecation_message: truncate(message, 500),
    deprecation_callsite: callsite
  }.compact

  metadata[:request_id] = OpenTrace.current_request_id if OpenTrace.current_request_id

  OpenTrace.log("WARN", "DEPRECATION: #{truncate(message, 200)}", metadata)
rescue StandardError
  # Swallow
end
```

**Example payload**:

```json
{
  "level": "WARN",
  "message": "DEPRECATION: ActiveRecord::Base.default_timezone is deprecated",
  "metadata": {
    "deprecation_message": "ActiveRecord::Base.default_timezone is deprecated, use ActiveRecord.default_timezone instead. (called from app/models/concerns/timezone_aware.rb:14)",
    "deprecation_callsite": "app/models/concerns/timezone_aware.rb:14:in `set_timezone'",
    "request_id": "req-abc123"
  }
}
```

**How Claude uses it**:

```
User: "We're planning a Rails 8.1 upgrade, any issues?"

Claude searches OpenTrace: level=WARN, message contains "DEPRECATION", last 7 days
Claude finds 3 unique deprecations:
  1. ActiveRecord::Base.default_timezone at timezone_aware.rb:14 — 847 occurrences
  2. config.active_record.sqlite3_production_warning — 1 occurrence
  3. acts_as_paranoid using removed API — 2340 occurrences
Claude provides: exact files to fix, gems to upgrade, which are blocked on gem updates
```

**Side effects**: Deprecation warnings fire infrequently in production (typically 0 per
request in clean apps, maybe 0-5 in apps with issues). One hash build + queue push per
warning. In development with verbose warnings this could fire more often, but dev is not
the concern — and `min_level: :error` would filter them.

**Risks**: None meaningful. The subscriber only runs when Rails emits a deprecation event.
The `rescue StandardError` block ensures no crash. If the `payload[:callstack]` format
changes between Rails versions, we get nil — which is `.compact`ed away.

---

### 1.5 Error Fingerprinting

**What it does**: Generates a stable hash from `exception_class` + first application-level
backtrace line. Groups identical errors so the OpenTrace server can show "this error occurred
N times" instead of N individual error logs.

**Why Claude needs it**: When Claude sees 342 error logs, it needs to know: is this 342
different bugs, or 1 bug that happened 342 times? Fingerprinting answers that instantly.
It also enables frequency tracking — "this started 2 hours ago and is accelerating" vs
"steady 5/hour for weeks."

**Implementation**:

File: `lib/opentrace/rails.rb` — new helper method

```ruby
require "digest"

def compute_error_fingerprint(exception_class, backtrace)
  # Use first app-level backtrace line (not gem code) for stability
  origin = if backtrace.is_a?(Array)
             backtrace.find { |l| l.include?("app/") || l.include?("lib/") } || backtrace.first
           end

  # Normalize: strip line numbers that change between deploys
  # "app/controllers/orders_controller.rb:18:in `show'" → "app/controllers/orders_controller.rb:in `show'"
  normalized_origin = origin&.gsub(/:\d+:/, ":") || "unknown"

  Digest::MD5.hexdigest("#{exception_class}||#{normalized_origin}")[0, 12]
end
```

Add to `forward_request_log` error branch:

```ruby
if payload[:exception]
  metadata[:exception_class]   = payload[:exception][0]
  metadata[:exception_message] = truncate(payload[:exception][1], 500)

  if payload[:exception_object]&.backtrace
    cleaned = clean_backtrace(payload[:exception_object].backtrace)
    metadata[:backtrace] = cleaned.first(15)
    metadata[:error_fingerprint] = compute_error_fingerprint(
      payload[:exception][0], cleaned
    )
  end
end
```

Also add to `forward_job_log` (for job failures) and `OpenTrace.error` (for manual error
reporting):

```ruby
# In OpenTrace.error method
if exception.backtrace
  cleaned = # ... existing backtrace cleaning ...
  meta[:backtrace] = cleaned.first(15)
  meta[:error_fingerprint] = compute_error_fingerprint(exception.class.name, cleaned)
end
```

**Example payload (added to existing error logs)**:

```json
{
  "level": "ERROR",
  "message": "GET /products/9942 404 2.1ms",
  "metadata": {
    "exception_class": "ActiveRecord::RecordNotFound",
    "exception_message": "Couldn't find Product with id=9942",
    "backtrace": ["app/controllers/products_controller.rb:18:in `show'"],
    "error_fingerprint": "a1b2c3d4e5f6",
    "controller": "ProductsController",
    "action": "show"
  }
}
```

**How Claude uses it**:

```
User: "We're seeing a lot of 404s, is something broken?"

Claude searches OpenTrace: level=ERROR, last 2 hours, groups by error_fingerprint
  fingerprint a1b2c3d4e5f6: RecordNotFound in ProductsController#show — 342x, started 2h ago
  fingerprint b2c3d4e5f6a1: RecordNotFound in CartItemsController#update — 3x, ongoing weeks
Claude focuses on first one (new, high volume)
Claude correlates with other logs → CleanupOldProductsJob ran at that time
Claude explains: Job deleted products still linked in cached pages and search results
```

**Side effects**: One MD5 hash computation (~500ns) only when an exception occurs. Never runs
on successful requests. MD5 is used for grouping, not security — it's fast and produces short,
stable 12-character hashes.

**Risks**: The fingerprint normalizes line numbers away (`gsub(/:\d+:/, ":")`), so the same
error at the same method produces the same fingerprint even across deploys that shift line
numbers. If a file is refactored significantly, the fingerprint changes — which is correct
behavior (it's a different code path now).

---

### 1.6 DB Connection Pool Stats

**What it does**: Periodically logs ActiveRecord connection pool statistics. Runs on a
background timer thread — **never in the request path**.

**Why Claude needs it**: `ActiveRecord::ConnectionTimeoutError` is one of the hardest Rails
errors to debug remotely. It's intermittent and load-dependent. Pool stats tell Claude:
"the pool has 5 connections but 10 threads are trying to use it, and 3 are waiting."

**Implementation**:

File: `lib/opentrace/pool_monitor.rb` (new file)

```ruby
# frozen_string_literal: true

module OpenTrace
  class PoolMonitor
    DEFAULT_INTERVAL = 30 # seconds

    def initialize(interval: DEFAULT_INTERVAL)
      @interval = interval
      @thread = nil
      @running = false
    end

    def start
      return if @running
      @running = true

      @thread = Thread.new do
        Thread.current.report_on_exception = false
        loop do
          sleep @interval
          break unless @running
          report_pool_stats
        rescue Exception # rubocop:disable Lint/RescueException
          # Swallow — never crash the host app
        end
      end
    end

    def stop
      @running = false
      @thread&.join(2)
    end

    private

    def report_pool_stats
      return unless OpenTrace.enabled?
      return unless defined?(::ActiveRecord::Base)

      pool = ActiveRecord::Base.connection_pool
      stat = pool.stat

      metadata = {
        metric_type: "db_pool",
        pool_size: stat[:size],
        connections_busy: stat[:busy],
        connections_dead: stat[:dead],
        connections_idle: stat[:idle],
        threads_waiting: stat[:waiting],
        checkout_timeout: stat[:checkout_timeout]
      }

      level = stat[:waiting].to_i > 0 ? "WARN" : "DEBUG"
      message = "DB pool: #{stat[:busy]}/#{stat[:size]} busy, #{stat[:waiting]} waiting"

      OpenTrace.log(level, message, metadata)
    end
  end
end
```

File: `lib/opentrace/rails.rb` — start monitor in `config.after_initialize`

```ruby
if OpenTrace.config.pool_monitoring
  require_relative "pool_monitor"
  @pool_monitor = OpenTrace::PoolMonitor.new(
    interval: OpenTrace.config.pool_monitoring_interval
  )
  @pool_monitor.start
end
```

File: `lib/opentrace/config.rb` — new options

```ruby
attr_accessor :pool_monitoring, :pool_monitoring_interval

def initialize
  # ... existing ...
  @pool_monitoring = false
  @pool_monitoring_interval = 30
end
```

**Example payload (emitted every 30s by background thread)**:

Normal state:

```json
{
  "level": "DEBUG",
  "message": "DB pool: 8/10 busy, 0 waiting",
  "metadata": {
    "metric_type": "db_pool",
    "pool_size": 10,
    "connections_busy": 8,
    "connections_dead": 0,
    "connections_idle": 2,
    "threads_waiting": 0,
    "checkout_timeout": 5.0
  }
}
```

Stressed state (auto-escalated to WARN):

```json
{
  "level": "WARN",
  "message": "DB pool: 10/10 busy, 3 waiting",
  "metadata": {
    "metric_type": "db_pool",
    "pool_size": 10,
    "connections_busy": 10,
    "connections_dead": 0,
    "connections_idle": 0,
    "threads_waiting": 3,
    "checkout_timeout": 5.0
  }
}
```

**How Claude uses it**:

```
User: "We're getting random ConnectionTimeoutError during peak hours"

Claude searches OpenTrace: metric_type=db_pool, level=WARN, last 24 hours
Claude sees: threads_waiting spikes to 3-5 between 2-4 PM daily
Claude correlates: ReportsController#generate holds connections for 8+ seconds
Claude suggests:
  1. Increase pool size in database.yml to match Puma thread count
  2. Move report generation to background job with separate connection pool
  3. Add statement_timeout to prevent long-running queries from holding connections
```

**Side effects**: Zero request-path overhead. Background thread calls `pool.stat` every 30
seconds. `pool.stat` acquires the pool's internal mutex briefly (~1μs) but at 30-second
intervals this is invisible. Thread stack adds ~0.5MB memory.

**Risks**: `pool.stat` is a public Rails API (since Rails 5.2) and safe to call. Thread uses
`report_on_exception = false` and `rescue Exception` matching existing dispatch thread
patterns. **Disabled by default** — user must opt in via `pool_monitoring = true`.

---

### 1.7 Job Queue Depth

**What it does**: Periodically logs job queue sizes and latencies for the configured job
backend (Sidekiq, GoodJob, or Solid Queue). Runs on a background timer.

**Why Claude needs it**: Queue depth explains why jobs are delayed. A job that takes 200ms
to execute but sits in a queue of 5,000 will appear fine in individual job logs. Queue depth
is the only way to see the backlog.

**Implementation**:

File: `lib/opentrace/queue_monitor.rb` (new file)

```ruby
# frozen_string_literal: true

module OpenTrace
  class QueueMonitor
    DEFAULT_INTERVAL = 60 # seconds

    def initialize(interval: DEFAULT_INTERVAL)
      @interval = interval
      @thread = nil
      @running = false
    end

    def start
      return if @running
      @running = true

      @thread = Thread.new do
        Thread.current.report_on_exception = false
        loop do
          sleep @interval
          break unless @running
          report_queue_stats
        rescue Exception # rubocop:disable Lint/RescueException
          # Swallow
        end
      end
    end

    def stop
      @running = false
      @thread&.join(2)
    end

    private

    def report_queue_stats
      return unless OpenTrace.enabled?

      queues = collect_queue_data
      return if queues.nil? || queues.empty?

      total_enqueued = queues.values.sum { |q| q[:size] }

      metadata = {
        metric_type: "queue_depth",
        queues: queues,
        total_enqueued: total_enqueued,
        adapter: detect_adapter
      }

      level = total_enqueued > 1000 ? "WARN" : "INFO"
      summary = queues.map { |name, data| "#{name}=#{data[:size]}" }.join(", ")
      message = "Queue stats: #{summary}"

      OpenTrace.log(level, message, metadata)
    end

    def detect_adapter
      if defined?(::Sidekiq)
        "sidekiq"
      elsif defined?(::GoodJob)
        "good_job"
      elsif defined?(::SolidQueue)
        "solid_queue"
      end
    end

    def collect_queue_data
      case detect_adapter
      when "sidekiq"    then sidekiq_stats
      when "good_job"   then good_job_stats
      when "solid_queue" then solid_queue_stats
      end
    rescue StandardError
      nil
    end

    def sidekiq_stats
      queues = {}
      Sidekiq::Queue.all.each do |queue|
        queues[queue.name] = {
          size: queue.size,
          latency_ms: (queue.latency * 1000).round(1)
        }
      end
      queues
    end

    def good_job_stats
      queues = {}
      GoodJob::Job.where(finished_at: nil)
                   .group(:queue_name)
                   .count
                   .each do |name, count|
        queues[name] = { size: count }
      end
      queues
    end

    def solid_queue_stats
      queues = {}
      SolidQueue::ReadyExecution.group(:queue_name)
                                 .count
                                 .each do |name, count|
        queues[name] = { size: count }
      end
      queues
    end
  end
end
```

File: `lib/opentrace/config.rb` — new options

```ruby
attr_accessor :queue_monitoring, :queue_monitoring_interval

def initialize
  # ... existing ...
  @queue_monitoring = false
  @queue_monitoring_interval = 60
end
```

**Example payload (emitted every 60s by background thread)**:

```json
{
  "level": "WARN",
  "message": "Queue stats: default=12, mailers=847, critical=0",
  "metadata": {
    "metric_type": "queue_depth",
    "adapter": "sidekiq",
    "queues": {
      "default": { "size": 12, "latency_ms": 1200.0 },
      "mailers": { "size": 847, "latency_ms": 62000.0 },
      "critical": { "size": 0, "latency_ms": 0 }
    },
    "total_enqueued": 859
  }
}
```

**How Claude uses it**:

```
User: "Password reset emails are delayed by 10+ minutes"

Claude searches OpenTrace: metric_type=queue_depth, last 2 hours
Claude sees: mailers queue spiked from 0 to 800+ at 14:00, latency 62s and climbing
Claude checks what happened at 14:00 → WeeklyDigestJob enqueued 10k emails into mailers queue
Claude suggests: Move WeeklyDigestJob to a "bulk_mail" queue with lower priority
```

**Side effects**: Zero request-path overhead. One background query every 60 seconds.
For Sidekiq: reads from Redis (~1ms). For GoodJob/SolidQueue: SQL COUNT query (< 5ms with
indexes).

**Risks**: The SQL query for GoodJob/SolidQueue could be slow on very large tables without
indexes, but at 60-second intervals even a 100ms query is invisible. Sidekiq requires the
`sidekiq` gem's API — the `defined?(::Sidekiq)` guard ensures we only call it when loaded.
**Disabled by default.**

---

## Phase 2: Accumulate-and-Summarize Architecture (v0.5.0)

This phase introduces the `RequestCollector` pattern and adds view/cache/summary/timeline
features that would be too expensive under the "one event = one queue push" model.

**Architectural change**: Individual subscriber events within a request accumulate in a
Fiber-local collector instead of pushing to the queue individually. One summary is emitted
at request end.

**External API change**: Request logs gain many new metadata fields. Individual SQL logs
for web requests are no longer emitted separately (they're included in the summary timeline).
SQL logs from background jobs and non-web contexts continue unchanged.

---

### 2.1 RequestCollector

**What it does**: Lightweight Fiber-local struct that accumulates event data during a request.
All subscribers write to it. At request end, it emits one summary payload.

**Why**: Without the collector, adding view rendering (200 partials) and cache operations
(50 reads) would generate 250 additional queue pushes per request. The collector reduces
this to 0 additional pushes.

**Implementation**:

File: `lib/opentrace/request_collector.rb` (new file)

```ruby
# frozen_string_literal: true

module OpenTrace
  class RequestCollector
    MAX_TIMELINE_EVENTS = 200

    attr_reader :sql_count, :sql_total_ms,
                :view_count, :view_total_ms,
                :cache_reads, :cache_hits, :cache_writes
    attr_accessor :memory_before, :memory_after

    def initialize(max_timeline: MAX_TIMELINE_EVENTS)
      @max_timeline = max_timeline

      @sql_count = 0
      @sql_total_ms = 0.0
      @sql_slowest_ms = 0.0
      @sql_slowest_name = nil

      @view_count = 0
      @view_total_ms = 0.0
      @view_slowest_ms = 0.0
      @view_slowest_template = nil

      @cache_reads = 0
      @cache_hits = 0
      @cache_writes = 0
      @cache_deletes = 0

      @http_count = 0
      @http_total_ms = 0.0
      @http_slowest_ms = 0.0
      @http_slowest_host = nil

      @timeline = []
      @request_start = Process.clock_gettime(Process::CLOCK_MONOTONIC)

      @memory_before = nil
      @memory_after = nil
    end

    def record_sql(name:, duration_ms:, table: nil)
      @sql_count += 1
      @sql_total_ms += duration_ms

      if duration_ms > @sql_slowest_ms
        @sql_slowest_ms = duration_ms
        @sql_slowest_name = name
      end

      append_timeline({ t: :sql, n: name, ms: duration_ms.round(1), at: offset_ms })
    end

    def record_view(template:, duration_ms:)
      @view_count += 1
      @view_total_ms += duration_ms

      if duration_ms > @view_slowest_ms
        @view_slowest_ms = duration_ms
        @view_slowest_template = template
      end

      append_timeline({ t: :view, n: template, ms: duration_ms.round(1), at: offset_ms })
    end

    def record_cache(action:, hit: nil, duration_ms: 0.0)
      case action
      when :read
        @cache_reads += 1
        @cache_hits += 1 if hit
      when :write
        @cache_writes += 1
      when :delete
        @cache_deletes += 1
      end

      append_timeline({ t: :cache, a: action, hit: hit, ms: duration_ms.round(2), at: offset_ms })
    end

    def record_http(method:, url:, host:, status:, duration_ms:, error: nil)
      @http_count += 1
      @http_total_ms += duration_ms

      if duration_ms > @http_slowest_ms
        @http_slowest_ms = duration_ms
        @http_slowest_host = host
      end

      entry = { t: :http, n: "#{method} #{host}", ms: duration_ms.round(1), s: status, at: offset_ms }
      entry[:err] = error if error
      append_timeline(entry)
    end

    def summary
      result = {
        sql_query_count: @sql_count,
        sql_total_ms: @sql_total_ms.round(1),
        sql_slowest_ms: @sql_slowest_ms.round(1),
        sql_slowest_name: @sql_slowest_name,
        view_render_count: @view_count,
        view_total_ms: @view_total_ms.round(1),
        view_slowest_ms: @view_slowest_ms.round(1),
        view_slowest_template: @view_slowest_template,
        cache_reads: @cache_reads,
        cache_hits: @cache_hits,
        cache_writes: @cache_writes,
        cache_hit_ratio: @cache_reads > 0 ? (@cache_hits.to_f / @cache_reads).round(2) : nil,
        n_plus_one_warning: @sql_count > 20 ? true : nil,
        timeline: @timeline.empty? ? nil : @timeline
      }

      # HTTP stats (only present if http_tracking is enabled and calls were made)
      if @http_count > 0
        result[:http_external_count] = @http_count
        result[:http_external_total_ms] = @http_total_ms.round(1)
        result[:http_slowest_ms] = @http_slowest_ms.round(1)
        result[:http_slowest_host] = @http_slowest_host
      end

      # Memory stats (only present if memory_tracking is enabled)
      if @memory_before && @memory_after
        result[:memory_before_mb] = @memory_before
        result[:memory_after_mb] = @memory_after
        result[:memory_delta_mb] = (@memory_after - @memory_before).round(1)
      end

      result.compact
    end

    private

    def offset_ms
      ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - @request_start) * 1000).round(1)
    end

    def append_timeline(entry)
      @timeline << entry if @timeline.size < @max_timeline
    end
  end
end
```

**Key design decisions**:

1. **Timeline capped at 200 entries**: Prevents unbounded memory growth. 200 events covers
   even complex pages. If a request has more than 200 events, the first 200 are kept (most
   likely to contain the root cause).

2. **Tracks "slowest" for SQL, views, HTTP**: Claude can immediately see the bottleneck
   without scanning the full timeline.

3. **Uses `Process::CLOCK_MONOTONIC`**: Not affected by NTP clock adjustments. Accurate
   offsets for the timeline waterfall.

4. **No locks**: Lives in `Fiber[]`, only accessed by current request's fiber/thread.

5. **Short timeline keys** (`t`, `n`, `ms`, `at`): Minimizes JSON payload size. A 200-entry
   timeline with short keys is ~8KB vs ~16KB with full names.

**Side effects**: One object allocation at request start (~200 bytes). Array appends during
the request (~20ns each). Total memory per request: ~2-10KB depending on event count. GC'd
when request ends.

---

### 2.2 View Render Tracking

**What it does**: Subscribes to `render_template.action_view` and `render_partial.action_view`.
Records each render event in the RequestCollector — **no individual queue pushes**.

**Why Claude needs it**: Slow templates and N+1 partial renders are the #2 cause of slow
Rails pages after N+1 queries. A page rendering `_line_item.html.erb` 150 times at 2ms each
= 300ms of rendering time that's invisible without view tracking.

**Implementation**:

File: `lib/opentrace/rails.rb` — new subscribers in `config.after_initialize`

```ruby
# View render tracking (only fires if RequestCollector exists)
%w[render_template.action_view render_partial.action_view].each do |event_name|
  ActiveSupport::Notifications.subscribe(event_name) do |*args|
    collector = Fiber[:opentrace_collector]
    next unless collector

    event = ActiveSupport::Notifications::Event.new(*args)
    template = event.payload[:identifier]
    # Shorten: /Users/deploy/app/views/orders/show.html.erb → orders/show.html.erb
    template = template.split("views/").last if template&.include?("views/")

    collector.record_view(template: template, duration_ms: event.duration || 0.0)
  rescue StandardError
    # Swallow
  end
end
```

**Example data (inside request summary, NOT as individual logs)**:

```json
{
  "metadata": {
    "view_render_count": 152,
    "view_total_ms": 315.4,
    "view_slowest_ms": 45.2,
    "view_slowest_template": "orders/show.html.erb",
    "timeline": [
      { "t": "view", "n": "orders/show.html.erb", "ms": 45.2, "at": 950.0 },
      { "t": "view", "n": "orders/_line_item.html.erb", "ms": 2.1, "at": 960.0 },
      { "t": "view", "n": "orders/_line_item.html.erb", "ms": 2.0, "at": 962.1 }
    ]
  }
}
```

**How Claude uses it**:

```
User: "Order detail page takes 8 seconds for orders with many items"

Claude searches OpenTrace: controller=OrdersController, action=show, duration_ms > 5000
Claude sees: view_render_count=350, view_total_ms=4200
  view_slowest_template=orders/_line_item.html.erb (rendered 340 times)
Claude reads app/views/orders/_line_item.html.erb
Claude finds: each partial calls product.image_variants.first → triggers SQL query
Claude suggests:
  1. Use render collection: @order.line_items (Rails optimizes this internally)
  2. Add includes(:product => :image_variants) to the controller
  3. Consider fragment caching: cache(@line_item) { ... }
```

**Side effects**: Each view render triggers the subscriber (~50ns for guard check + array
append). For 200 partials, total overhead is ~10μs. **No queue pushes**.

**Without accumulate pattern this would cost**: 200 queue pushes per request = ~200μs of
mutex contention + 200 hash allocations + queue overflow risk. That's why this requires the
collector.

**Risks**: None. The `next unless collector` guard immediately exits if no RequestCollector
exists (e.g., outside web requests, in background jobs). Timeline capped at 200 entries.

---

### 2.3 Cache Operation Tracking

**What it does**: Subscribes to `cache_read.active_support`, `cache_write.active_support`,
and `cache_delete.active_support`. Records each operation in the RequestCollector.

**Why Claude needs it**: Cache misses are a silent performance killer. A cache hit takes 0.5ms.
A miss triggers a database query (50ms) or API call (500ms). When 10 cache keys expire
simultaneously, a request goes from 200ms to 5 seconds. Without cache visibility, Claude
can't correlate "slow request" with "all caches expired."

**Implementation**:

File: `lib/opentrace/rails.rb` — new subscribers

```ruby
# Cache operation tracking (only fires if RequestCollector exists)
%w[cache_read.active_support cache_write.active_support cache_delete.active_support].each do |event_name|
  ActiveSupport::Notifications.subscribe(event_name) do |*args|
    collector = Fiber[:opentrace_collector]
    next unless collector

    event = ActiveSupport::Notifications::Event.new(*args)
    action = event_name.split(".").first.sub("cache_", "").to_sym  # :read, :write, :delete

    collector.record_cache(
      action: action,
      hit: event.payload[:hit],  # only present for reads
      duration_ms: event.duration || 0.0
    )
  rescue StandardError
    # Swallow
  end
end
```

**Example data (inside request summary)**:

```json
{
  "metadata": {
    "cache_reads": 14,
    "cache_hits": 2,
    "cache_writes": 12,
    "cache_hit_ratio": 0.14,
    "timeline": [
      { "t": "cache", "a": "read", "hit": false, "ms": 0.8, "at": 52.0 },
      { "t": "cache", "a": "write", "ms": 0.5, "at": 102.0 },
      { "t": "cache", "a": "read", "hit": true, "ms": 0.1, "at": 105.0 }
    ]
  }
}
```

**How Claude uses it**:

```
User: "We deployed 30 minutes ago and response times spiked, now slowly recovering"

Claude searches OpenTrace: last hour, sorted by time
Claude sees: cache_hit_ratio dropped from 0.95 to 0.10 right after deploy, climbing back
Claude checks deploy diff (via git_sha) → cache key version bumped v2 → v3
Claude explains: Deploy invalidated all fragment caches at once. Suggests touch: true
on associations for gradual invalidation, or add cache warming to deploy script.
```

**Side effects**: Same as view tracking. ~50ns per cache operation (guard + array append).
Typical request has 5-20 cache operations. Total: ~0.25-1μs.

**Risks**: None. Same guard pattern. No queue pushes. Bounded timeline.

---

### 2.4 Per-Request Summary

**What it does**: At request end, the controller subscriber merges the RequestCollector's
summary into the existing controller log. **One log entry per request with everything.**

**Why Claude needs it**: The single most powerful debugging feature. One log entry answers
"where did the time go?" Claude triages any slow request in seconds instead of correlating
dozens of individual logs.

**Implementation**:

File: `lib/opentrace/middleware.rb` — create and destroy collector

```ruby
def call(env)
  request_id = env["action_dispatch.request_id"] || env["HTTP_X_REQUEST_ID"]
  OpenTrace.current_request_id = request_id

  if OpenTrace.enabled? && OpenTrace.config.request_summary
    Fiber[:opentrace_collector] = OpenTrace::RequestCollector.new(
      max_timeline: OpenTrace.config.timeline_max_events
    )
  end

  @app.call(env)
ensure
  Fiber[:opentrace_collector] = nil
  OpenTrace.current_request_id = nil
end
```

File: `lib/opentrace/rails.rb` — modified `forward_request_log`

```ruby
def forward_request_log(event)
  return unless OpenTrace.enabled?

  payload = event.payload
  return if ignored_path?(payload[:path])

  metadata = {
    request_id: payload[:headers]&.env&.dig("action_dispatch.request_id"),
    controller: payload[:controller],
    action: payload[:action],
    method: payload[:method],
    path: payload[:path],
    status: payload[:status],
    duration_ms: event.duration&.round(1)
  }.compact

  # ... existing user_id, exception, params extraction ...

  # Request headers (Phase 1)
  extract_request_headers(payload, metadata)

  # Error fingerprint (Phase 1)
  if metadata[:backtrace]
    metadata[:error_fingerprint] = compute_error_fingerprint(
      metadata[:exception_class], metadata[:backtrace]
    )
  end

  # N+1 counter (Phase 1 Fiber-locals — used when collector not present)
  unless Fiber[:opentrace_collector]
    metadata[:sql_query_count] = Fiber[:opentrace_sql_count] if Fiber[:opentrace_sql_count]
    metadata[:sql_total_ms] = Fiber[:opentrace_sql_total_ms]&.round(1) if Fiber[:opentrace_sql_total_ms]
  end

  # Merge collector summary (Phase 2)
  collector = Fiber[:opentrace_collector]
  if collector
    metadata.merge!(collector.summary)

    # Compute time breakdown
    total = event.duration || 0.0
    if total > 0
      sql_pct = ((collector.sql_total_ms / total) * 100).round(1)
      view_pct = ((collector.view_total_ms / total) * 100).round(1)
      http_pct = collector.instance_variable_get(:@http_total_ms)
      http_pct = http_pct ? ((http_pct / total) * 100).round(1) : 0.0
      other_pct = [100 - sql_pct - view_pct - http_pct, 0].max.round(1)
      metadata[:time_breakdown] = {
        sql_pct: sql_pct,
        view_pct: view_pct,
        http_pct: http_pct,
        other_pct: other_pct
      }
    end
  end

  level = determine_level(payload)
  message = "#{payload[:method]} #{payload[:path]} #{payload[:status]} #{event.duration&.round(1)}ms"

  OpenTrace.log(level, message, metadata)
rescue StandardError
  # Swallow
end
```

File: `lib/opentrace/config.rb` — new options

```ruby
attr_accessor :request_summary, :timeline, :timeline_max_events

def initialize
  # ... existing ...
  @request_summary = true
  @timeline = true
  @timeline_max_events = 200
end
```

**Example: The complete request summary payload**:

```json
{
  "level": "INFO",
  "message": "GET /dashboard 200 2847ms",
  "service": "my-app",
  "environment": "production",
  "timestamp": "2026-02-12T14:30:45.123456Z",
  "metadata": {
    "request_id": "req-abc123",
    "controller": "DashboardController",
    "action": "index",
    "method": "GET",
    "path": "/dashboard",
    "status": 200,
    "duration_ms": 2847.3,
    "user_id": 42,

    "request_accept": "text/html",
    "request_user_agent": "Mozilla/5.0...",

    "sql_query_count": 34,
    "sql_total_ms": 423.1,
    "sql_slowest_ms": 312.0,
    "sql_slowest_name": "Order Count",
    "n_plus_one_warning": true,

    "view_render_count": 48,
    "view_total_ms": 890.2,
    "view_slowest_ms": 245.0,
    "view_slowest_template": "dashboard/_activity_feed.html.erb",

    "cache_reads": 8,
    "cache_hits": 5,
    "cache_writes": 3,
    "cache_hit_ratio": 0.63,

    "time_breakdown": {
      "sql_pct": 14.9,
      "view_pct": 31.3,
      "http_pct": 0.0,
      "other_pct": 53.8
    },

    "timeline": [
      { "t": "sql", "n": "User Load", "ms": 1.2, "at": 0.0 },
      { "t": "sql", "n": "Order Load", "ms": 2.4, "at": 3.1 },
      { "t": "cache", "a": "read", "hit": true, "ms": 0.1, "at": 6.0 },
      { "t": "sql", "n": "Order Count", "ms": 312.0, "at": 10.0 },
      { "t": "view", "n": "dashboard/index.html.erb", "ms": 890.2, "at": 350.0 },
      { "t": "view", "n": "dashboard/_activity_feed.html.erb", "ms": 245.0, "at": 355.0 }
    ],

    "hostname": "web-3",
    "pid": 12345,
    "git_sha": "a1b2c3d"
  }
}
```

**How Claude uses it**:

```
User: "The app feels sluggish, can you investigate?"

Claude searches OpenTrace: duration_ms > 1000, last hour
Claude reads one summary → immediately knows:
  - 14.9% SQL, 31.3% views, 53.8% unaccounted (suggests external HTTP — Phase 3)
  - N+1 warning: 34 queries, slowest "Order Count" at 312ms
  - Cache hit ratio 63% (could be higher)
  - Slowest view: _activity_feed at 245ms
Claude provides actionable fixes without reading any other logs
```

**Side effects**: One `.summary` call at end of request (builds hash from instance variables,
~2μs). One `.merge!` to combine with existing metadata. The collector object is GC'd after
the request.

---

### 2.5 Request Timeline

**What it does**: The timeline is built automatically by the RequestCollector as events are
recorded. It's an ordered array of lightweight event entries showing what happened and when
during the request.

**Why Claude needs it**: The summary tells Claude "34 SQL queries totaling 423ms." The
timeline tells Claude "the first 3 queries took 5ms total, then there's a 400ms gap, then
31 identical queries in a tight loop." Timeline reveals causality and patterns that aggregates
hide.

**Implementation**: Already built into the RequestCollector (section 2.1). Populated by
`record_sql`, `record_view`, `record_cache`, `record_http`. Included in the summary hash.

**Timeline entry format reference**:

```ruby
# SQL
{ t: :sql, n: "User Load", ms: 1.2, at: 3.1 }

# View
{ t: :view, n: "orders/_line_item.html.erb", ms: 2.1, at: 960.0 }

# Cache
{ t: :cache, a: :read, hit: false, ms: 0.8, at: 52.0 }

# External HTTP (Phase 3 only)
{ t: :http, n: "POST api.stripe.com", ms: 890.0, s: 200, at: 55.0 }
```

Field reference:
- `t` — type (sql, view, cache, http). Short key to minimize JSON payload.
- `n` — name/identifier.
- `ms` — duration in milliseconds.
- `at` — offset from request start in milliseconds.
- `a` — action (cache only: read/write/delete).
- `hit` — cache hit/miss (cache reads only).
- `s` — HTTP status (http only, Phase 3).
- `err` — error class name (http failures only, Phase 3).

**How Claude uses it**:

```
User: "Order #42 took over a second to load, customer complained"

Claude searches OpenTrace: path=/orders/42, duration_ms > 1000
Claude reads the timeline:
  at=0ms:    SQL User Load (1.2ms)
  at=3ms:    SQL Order Load (2.4ms)
  at=6ms:    SQL LineItem Load (45ms)     ← slow query
  at=52ms:   cache read product/99 (hit)
  at=55ms:   [gap of 895ms]              ← this is untracked time (external HTTP?)
  at=950ms:  view orders/show.html.erb (120ms)
  at=960ms:  view orders/_line_item.html.erb x12 (2.1ms each)
  at=1100ms: SQL AuditLog Create (3.2ms)

Claude identifies: 895ms gap between cache read and view render. Likely an external HTTP
call. LineItem Load at 45ms may have missing index. Suggests enabling http_tracking (Phase 3)
to see the hidden call.
```

**Payload size consideration**: A full 200-entry timeline adds ~8-12KB to JSON. The existing
32KB payload limit handles this. Update `truncate_payload` to remove `timeline` first:

File: `lib/opentrace/client.rb` — updated `truncate_payload`

```ruby
def truncate_payload(payload)
  meta = payload[:metadata]&.dup || {}

  # Truncation priority: remove largest optional fields first
  meta.delete(:timeline)       # NEW — largest field, remove first
  meta.delete(:backtrace)
  meta.delete(:params)
  meta.delete(:job_arguments)
  meta[:sql] = meta[:sql][0, 200] + "..." if meta[:sql].is_a?(String) && meta[:sql].length > 200
  meta[:exception_message] = meta[:exception_message][0, 200] + "..." if meta[:exception_message].is_a?(String) && meta[:exception_message].length > 200

  payload.merge(metadata: meta)
end
```

**Side effects**: Each timeline entry is ~80 bytes. 200 entries = ~16KB allocated during the
request, GC'd at request end. The 200-entry cap means very complex requests lose tail events
— acceptable since the first 200 events almost always contain the root cause.

---

## Phase 3: Opt-In Advanced Features (v0.6.0)

These features have measurable overhead or implementation risks. **Disabled by default.**
Require explicit opt-in via configuration.

---

### 3.1 Memory Delta Tracking

**What it does**: Snapshots process memory before and after each request. Reports the delta
in the request summary to identify memory-heavy requests and gradual leaks.

**Why Claude needs it**: "Workers get OOM-killed after a few hours" is impossible to debug
without knowing which requests allocate the most memory. Memory deltas turn a mystery into
a query: "show me requests where memory_delta_mb > 50."

**Implementation**:

File: `lib/opentrace/middleware.rb` — add memory snapshots

```ruby
def call(env)
  request_id = env["action_dispatch.request_id"] || env["HTTP_X_REQUEST_ID"]
  OpenTrace.current_request_id = request_id

  if OpenTrace.enabled? && OpenTrace.config.request_summary
    collector = OpenTrace::RequestCollector.new(
      max_timeline: OpenTrace.config.timeline_max_events
    )
    Fiber[:opentrace_collector] = collector

    # Memory snapshot before request (opt-in)
    if OpenTrace.config.memory_tracking
      collector.memory_before = current_rss_mb
    end
  end

  @app.call(env)
ensure
  # Memory snapshot after request (opt-in)
  collector = Fiber[:opentrace_collector]
  if collector && OpenTrace.config.memory_tracking && collector.memory_before
    collector.memory_after = current_rss_mb
  end

  Fiber[:opentrace_collector] = nil
  OpenTrace.current_request_id = nil
end

private

def current_rss_mb
  if RUBY_PLATFORM.include?("linux")
    # Linux: read from /proc — no fork, ~10μs
    File.read("/proc/self/statm").split[1].to_i * 4096.0 / 1024 / 1024
  else
    # macOS/other: use GC.stat as lightweight approximation
    # Avoids forking a `ps` subprocess which costs 2-5ms
    gc = GC.stat
    gc[:heap_live_slots].to_f * 40 / 1024 / 1024  # rough estimate: ~40 bytes per slot
  end
rescue StandardError
  nil
end
```

File: `lib/opentrace/config.rb` — new option

```ruby
attr_accessor :memory_tracking

def initialize
  # ... existing ...
  @memory_tracking = false
end
```

**Example data (added to request summary when opt-in)**:

```json
{
  "metadata": {
    "memory_before_mb": 256.0,
    "memory_after_mb": 340.2,
    "memory_delta_mb": 84.2
  }
}
```

**How Claude uses it**:

```
User: "Workers get OOM-killed every few hours"

Claude searches OpenTrace: memory_delta_mb > 50, last 24 hours
Claude finds: ReportsController#export averages +80MB per request, called 20x/hour
Claude reads controller → CSV.generate loads everything into memory
Claude suggests: Stream the CSV with ActionController::Live or chunked send_data
```

**Side effects**:

| Platform | Method | Cost per call | 2 calls/request |
|----------|--------|---------------|-----------------|
| Linux | `/proc/self/statm` read | ~10μs | ~20μs |
| macOS | `GC.stat` (approximation) | ~5μs | ~10μs |

These are acceptable for opt-in use. The macOS approach avoids forking a `ps` subprocess
(which would cost 2-5ms — unacceptable).

**Risks**:
- RSS is process-level, not request-level. Concurrent requests pollute the delta. Documented
  as an approximation. On single-threaded servers (Unicorn) it's accurate.
- The macOS `GC.stat` approximation gives object-count-based estimates, not actual RSS.
  Useful for relative comparison between requests but not absolute values.
- **Disabled by default.** User must opt in.

---

### 3.2 External HTTP Tracking

**What it does**: Instruments outbound `Net::HTTP` calls to capture URL, method, status, and
duration. Records in the RequestCollector for the timeline.

**Why Claude needs it**: Third-party API calls are the #1 cause of intermittent production
failures. When Stripe is slow, checkout is slow. Without HTTP tracking, Claude sees the
symptom (slow request) but can't see the cause (Stripe returned 503 after 5 seconds).

**Implementation**:

File: `lib/opentrace/http_tracker.rb` (new file)

```ruby
# frozen_string_literal: true

module OpenTrace
  module HttpTracker
    def request(req, body = nil, &block)
      # Guard 1: skip if disabled
      return super unless OpenTrace.enabled?

      # Guard 2: skip if this IS an OpenTrace dispatch call (prevent infinite recursion)
      return super if Fiber[:opentrace_http_tracking_disabled]

      collector = Fiber[:opentrace_collector]
      start_time = Process.clock_gettime(Process::CLOCK_MONOTONIC)

      response = super

      duration_ms = (Process.clock_gettime(Process::CLOCK_MONOTONIC) - start_time) * 1000
      host = self.address
      port = self.port
      scheme = use_ssl? ? "https" : "http"
      url = "#{scheme}://#{host}#{port == 443 || port == 80 ? '' : ":#{port}"}#{req.path}"

      if collector
        collector.record_http(
          method: req.method,
          url: url,
          host: host,
          status: response.code.to_i,
          duration_ms: duration_ms
        )
      end

      response
    rescue IOError, SystemCallError, OpenSSL::SSL::SSLError, Timeout::Error, Net::ProtocolError => e
      # Record the failed HTTP call, then re-raise
      duration_ms = start_time ? (Process.clock_gettime(Process::CLOCK_MONOTONIC) - start_time) * 1000 : 0

      if collector
        collector.record_http(
          method: req&.method,
          url: "#{self.address}#{req&.path}",
          host: self.address,
          status: 0,
          duration_ms: duration_ms,
          error: e.class.name
        )
      end

      raise  # ALWAYS re-raise — never swallow app errors
    end
  end
end
```

File: `lib/opentrace/client.rb` — add recursion guard to `send_batch`

```ruby
def send_batch(uri, batch)
  # Disable HTTP tracking for our own calls to prevent infinite recursion
  Fiber[:opentrace_http_tracking_disabled] = true

  # ... existing send logic ...
ensure
  Fiber[:opentrace_http_tracking_disabled] = nil
end
```

File: `lib/opentrace/rails.rb` — activate when configured

```ruby
if OpenTrace.config.http_tracking
  require_relative "http_tracker"
  Net::HTTP.prepend(OpenTrace::HttpTracker)
end
```

File: `lib/opentrace/config.rb` — new option

```ruby
attr_accessor :http_tracking

def initialize
  # ... existing ...
  @http_tracking = false
end
```

**Example data (inside request summary when opt-in)**:

```json
{
  "metadata": {
    "http_external_count": 2,
    "http_external_total_ms": 1504.0,
    "http_slowest_ms": 1320.0,
    "http_slowest_host": "api.analytics-provider.com",
    "timeline": [
      { "t": "sql", "n": "User Load", "ms": 1.2, "at": 0.0 },
      { "t": "http", "n": "POST api.stripe.com", "ms": 184.0, "s": 200, "at": 55.0 },
      { "t": "http", "n": "GET api.analytics-provider.com", "ms": 1320.0, "s": 200, "at": 240.0 },
      { "t": "view", "n": "orders/show.html.erb", "ms": 120.4, "at": 1560.0 }
    ],
    "time_breakdown": {
      "sql_pct": 0.1,
      "view_pct": 7.2,
      "http_pct": 89.5,
      "other_pct": 3.2
    }
  }
}
```

Failed HTTP call example:

```json
{ "t": "http", "n": "POST api.stripe.com", "ms": 5200.0, "s": 0, "err": "Net::ReadTimeout", "at": 55.0 }
```

**How Claude uses it**:

```
User: "Checkout is failing intermittently"

Claude searches OpenTrace: controller=OrdersController, action=create, level=ERROR
Claude sees: http_slowest_host=api.stripe.com, timeline shows s=503 and s=0 (timeout)
Claude identifies: Stripe API intermittent outage, not a code bug
Claude suggests:
  1. Add retry with exponential backoff for Stripe calls
  2. Implement circuit breaker pattern
  3. Show customer a "payment processing" state with async confirmation
```

**Side effects per HTTP call**:

| Operation | Cost |
|-----------|------|
| Guard check (`if Fiber[...]`) | ~5ns |
| `Process.clock_gettime` x2 | ~20ns |
| Hash construction | ~50ns |
| Array append to collector | ~20ns |
| **Total** | **~100ns** |

HTTP calls typically take 50-5000ms, so 100ns overhead is invisible.

**Risks**:

1. **Infinite recursion**: The gem's own HTTP calls to the OpenTrace server go through
   `Net::HTTP`. The `Fiber[:opentrace_http_tracking_disabled]` guard in `client.rb`
   prevents this. **Must have integration tests verifying this.**

2. **Gem compatibility**: Some HTTP gems (Faraday, HTTParty, RestClient) use `Net::HTTP`
   internally. The prepend captures these — which is desirable. But gems with their own
   `Net::HTTP` monkey-patches could conflict. Risk is low but non-zero.

3. **Error re-raising**: The rescue block captures specific network errors, records them,
   and re-raises. The app's error handling is never affected. We rescue specific exception
   classes (not `StandardError`) to avoid catching unrelated errors.

4. **Thread safety**: `Fiber[]` guard is fiber-local. Concurrent requests in different
   fibers/threads don't interfere. HTTP calls in thread pools (e.g., `Concurrent::Future`)
   won't have a collector and are skipped (correct behavior).

**Why opt-in**: Monkey-patching `Net::HTTP` is the most invasive thing this gem does. It
affects every HTTP call in the process. While the implementation is safe, the surface area
for unexpected interactions is large. Users should test in staging first.

---

## Config Reference

### Complete configuration after all phases

```ruby
OpenTrace.configure do |c|
  # === Existing options (unchanged from v0.3.0) ===
  c.endpoint = "https://opentrace.example.com"    # Required
  c.api_key = "your-api-key"                       # Required
  c.service = "my-app"                              # Required
  c.environment = "production"                      # Optional
  c.timeout = 1.0                                   # HTTP timeout (default: 1.0s)
  c.batch_size = 50                                 # Logs per batch (default: 50)
  c.flush_interval = 5.0                            # Seconds between flushes (default: 5.0)
  c.min_level = :debug                              # Minimum log level (default: :debug)
  c.context = { tenant: "acme" }                    # Global context hash or Proc
  c.sql_logging = true                              # SQL query logging (default: true)
  c.sql_duration_threshold_ms = 0.0                 # SQL threshold (default: 0.0 = all)
  c.ignore_paths = ["/health", %r{\A/assets/}]     # Paths to skip (default: [])

  # === Phase 1 (v0.4.0) — always-on features (zero cost) ===
  # N+1 counter:          always on, piggybacks on SQL subscriber
  # Request headers:      always on, 4 hash reads
  # Job queue latency:    always on, 1 time subtraction
  # Deprecation warnings: always on, fires rarely
  # Error fingerprinting: always on, only on errors

  c.pool_monitoring = false                         # DB pool stats (default: false)
  c.pool_monitoring_interval = 30                   # Seconds between checks (default: 30)
  c.queue_monitoring = false                        # Job queue depth (default: false)
  c.queue_monitoring_interval = 60                  # Seconds between checks (default: 60)

  # === Phase 2 (v0.5.0) — on by default, very low cost ===
  c.request_summary = true                          # Per-request summary (default: true)
  c.timeline = true                                 # Include timeline in summary (default: true)
  c.timeline_max_events = 200                       # Max timeline entries (default: 200)

  # === Phase 3 (v0.6.0) — opt-in only ===
  c.memory_tracking = false                         # Memory delta per request (default: false)
  c.http_tracking = false                           # External HTTP tracking (default: false)
end
```

### Overhead summary table

| Feature | Default | Phase | Per-request overhead | Notes |
|---------|---------|-------|---------------------|-------|
| N+1 counter | always on | 1 | ~2ns/query | Fiber-local integer |
| Request headers | always on | 1 | ~50ns | 4 env hash reads |
| Job queue latency | always on | 1 | ~1μs | Per job only |
| Deprecation warnings | always on | 1 | ~0 | Fires rarely |
| Error fingerprinting | always on | 1 | ~500ns | Error path only |
| pool_monitoring | false | 1 | 0 | Background thread |
| queue_monitoring | false | 1 | 0 | Background thread |
| request_summary | true | 2 | ~2μs | End-of-request hash build |
| timeline | true | 2 | ~20ns/event | Array append |
| view tracking | (with summary) | 2 | ~50ns/render | Guard + append |
| cache tracking | (with summary) | 2 | ~50ns/cache op | Guard + append |
| memory_tracking | false | 3 | 10-20μs (Linux) | /proc read |
| http_tracking | false | 3 | ~100ns/HTTP call | Guard + append |

---

## Migration Guide

### v0.3.0 → v0.4.0

**No breaking changes.** Existing logs gain new metadata fields:

- Controller logs: `sql_query_count`, `sql_total_ms`, `n_plus_one_warning`,
  `request_content_type`, `request_accept`, `request_user_agent`, `request_referer`
- Job logs: `queue_latency_ms`, `enqueued_at`
- Error logs: `error_fingerprint`
- New log type: deprecation warnings (level: WARN)

If `pool_monitoring` or `queue_monitoring` are enabled, new periodic logs appear with
`metric_type: "db_pool"` or `metric_type: "queue_depth"`.

**Action required**: None. All features are additive. No existing fields changed or removed.

### v0.4.0 → v0.5.0

**Behavioral change**: When `request_summary` is true (default), individual SQL log entries
are still emitted for web requests AND the request summary includes accumulated SQL stats
and timeline. This means SQL data appears in both places.

If you want to reduce log volume, set `sql_logging = false` and rely on the request summary
timeline for SQL visibility. Or keep both for maximum debugging data.

**New metadata fields in controller logs**: `view_render_count`, `view_total_ms`,
`view_slowest_*`, `cache_reads`, `cache_hits`, `cache_writes`, `cache_hit_ratio`,
`time_breakdown`, `timeline`.

**Action required**: None for default behavior. If storage is a concern, consider setting
`sql_logging = false` to deduplicate SQL data.

### v0.5.0 → v0.6.0

**No breaking changes.** Two new opt-in features:

- `memory_tracking = true`: Adds `memory_before_mb`, `memory_after_mb`, `memory_delta_mb`
- `http_tracking = true`: Adds `http_external_count`, `http_external_total_ms`,
  `http_slowest_*` and HTTP events in timeline

**Action required**: None unless you opt in. If enabling `http_tracking`, test in staging
first to ensure no conflicts with HTTP gems in your stack.

---

## File Changes Summary

### Phase 1 — Modified files

| File | Change |
|------|--------|
| `lib/opentrace/config.rb` | Add `pool_monitoring`, `pool_monitoring_interval`, `queue_monitoring`, `queue_monitoring_interval` attrs and defaults |
| `lib/opentrace/middleware.rb` | Initialize/cleanup Fiber-local SQL counters |
| `lib/opentrace/rails.rb` | Add SQL counter to SQL subscriber, headers to controller subscriber, queue latency to job subscriber, error fingerprint to error paths, deprecation subscriber, pool/queue monitor startup |
| `lib/opentrace.rb` | Add error fingerprint to `error()` method, add `require "digest"` |
| `lib/opentrace/version.rb` | Bump to `"0.4.0"` |

### Phase 1 — New files

| File | Purpose |
|------|---------|
| `lib/opentrace/pool_monitor.rb` | Background DB connection pool monitoring |
| `lib/opentrace/queue_monitor.rb` | Background job queue depth monitoring |

### Phase 2 — Modified files

| File | Change |
|------|--------|
| `lib/opentrace/config.rb` | Add `request_summary`, `timeline`, `timeline_max_events` attrs |
| `lib/opentrace/middleware.rb` | Create/destroy RequestCollector per request |
| `lib/opentrace/rails.rb` | Refactor SQL subscriber to use collector, add view/cache subscribers, merge summary in controller subscriber |
| `lib/opentrace/client.rb` | Add `timeline` to truncation priority in `truncate_payload` |
| `lib/opentrace.rb` | Add `require_relative "opentrace/request_collector"` |
| `lib/opentrace/version.rb` | Bump to `"0.5.0"` |

### Phase 2 — New files

| File | Purpose |
|------|---------|
| `lib/opentrace/request_collector.rb` | Per-request event accumulator with timeline |

### Phase 3 — Modified files

| File | Change |
|------|--------|
| `lib/opentrace/config.rb` | Add `memory_tracking`, `http_tracking` attrs |
| `lib/opentrace/middleware.rb` | Add memory snapshots before/after request |
| `lib/opentrace/request_collector.rb` | Already has `record_http` and `memory_before/after` |
| `lib/opentrace/client.rb` | Add `Fiber[:opentrace_http_tracking_disabled]` guard in `send_batch` |
| `lib/opentrace/rails.rb` | Activate HTTP tracker when configured |
| `lib/opentrace/version.rb` | Bump to `"0.6.0"` |

### Phase 3 — New files

| File | Purpose |
|------|---------|
| `lib/opentrace/http_tracker.rb` | `Net::HTTP` prepend module for outbound HTTP tracking |

---

## Test Plan

### General test requirements for all features

Every feature must test:

1. **Correctness**: Does it capture the right data in the right format?
2. **Disabled state**: Does it do nothing when `OpenTrace.enabled?` returns false?
3. **Error swallowing**: Does a bug in the feature never crash the host app?
4. **Fiber-local isolation**: Do values not leak between requests?
5. **Payload size**: Does the new data fit within the 32KB payload limit?
6. **Integration**: Does it work in a full Rails request cycle end-to-end?

### Phase 1 test files

**`spec/opentrace/rails_n1_spec.rb`** (new):
- SQL counter increments per query
- Counter resets between requests (Fiber-local isolation)
- `n_plus_one_warning: true` when count > 20
- Counter works when `sql_logging = false` (counter is independent)
- Counter is nil outside web requests (no middleware)

**`spec/opentrace/rails_headers_spec.rb`** (new):
- Captures Content-Type, Accept, User-Agent, Referer
- Truncates long User-Agent to 200 chars
- Omits nil headers (`.compact`)
- No crash when `payload[:headers]` is nil

**`spec/integration/job_subscriber_spec.rb`** (modify):
- Add tests for `queue_latency_ms` and `enqueued_at`
- Test with nil `enqueued_at` (no crash)
- Test with string vs Time `enqueued_at`

**`spec/opentrace/deprecation_spec.rb`** (new):
- Captures deprecation message and callsite
- Logs at WARN level
- Includes request_id when in web context
- No crash when callstack is nil

**`spec/opentrace/error_fingerprint_spec.rb`** (new):
- Same error at same location produces same fingerprint
- Different errors produce different fingerprints
- Fingerprint stable across line number changes (gsub normalization)
- Works in controller subscriber, job subscriber, and `OpenTrace.error`
- No crash when backtrace is nil

**`spec/opentrace/pool_monitor_spec.rb`** (new):
- Reports pool stats at configured interval
- Escalates to WARN when threads_waiting > 0
- Does nothing when disabled
- Stops cleanly on `.stop`
- Swallows all errors

**`spec/opentrace/queue_monitor_spec.rb`** (new):
- Detects Sidekiq/GoodJob/SolidQueue correctly
- Reports queue sizes
- Escalates to WARN when total > 1000
- Does nothing when no adapter detected
- Swallows all errors

### Phase 2 test files

**`spec/opentrace/request_collector_spec.rb`** (new):
- `record_sql` increments count and tracks slowest
- `record_view` increments count and tracks slowest
- `record_cache` tracks hits/misses/writes correctly
- `cache_hit_ratio` computation correct (including zero-reads case)
- Timeline capped at `max_timeline` entries
- Timeline entries have correct `at` offsets (monotonic)
- `summary` returns `.compact`ed hash (no nil values)

**`spec/integration/view_tracking_spec.rb`** (new):
- Records template and partial renders
- Shortens template paths (strips prefix up to `views/`)
- Does not record when no collector (outside web request)
- Does not push to queue individually

**`spec/integration/cache_tracking_spec.rb`** (new):
- Records cache reads (hit and miss), writes, deletes
- Does not record when no collector
- Does not push to queue individually

**`spec/integration/request_summary_spec.rb`** (new):
- Complete request summary includes SQL, view, cache stats
- time_breakdown percentages sum to ~100
- Timeline appears in summary when enabled
- Summary disabled when `request_summary = false`
- Timeline disabled when `timeline = false`

### Phase 3 test files

**`spec/opentrace/memory_tracking_spec.rb`** (new):
- Records before/after memory snapshots
- Delta appears in summary
- No crash when `/proc/self/statm` doesn't exist (macOS fallback)
- Does nothing when `memory_tracking = false`

**`spec/opentrace/http_tracker_spec.rb`** (new):
- **Critical: no infinite recursion** — OpenTrace's own HTTP POST must not be tracked
- Records method, URL, host, status, duration
- Records failed HTTP calls with error class
- **Re-raises all HTTP errors** — never swallows app exceptions
- Does nothing when disabled
- Does nothing when no collector (outside web request)
- Works with Faraday (which wraps Net::HTTP)

### End-to-end integration test

**`spec/integration/end_to_end_enhanced_spec.rb`** (new):

Full Rails request cycle with all features enabled:
1. Request hits middleware → collector created
2. Controller queries DB (3 times) → SQL recorded in collector
3. Cache read (miss) → recorded
4. External HTTP call (mocked) → recorded (if http_tracking on)
5. View renders (2 templates) → recorded
6. Controller finishes → summary emitted with all data
7. Verify: single queue push contains SQL stats, view stats, cache stats, timeline,
   headers, N+1 flag, time_breakdown
8. Verify: cleanup — Fiber-locals are nil after request
