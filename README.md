# OpenTrace Ruby

[![Gem Version](https://badge.fury.io/rb/opentrace.svg)](https://rubygems.org/gems/opentrace)
[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)

A thin, safe Ruby client that forwards structured application logs to an [OpenTrace](https://github.com/adham90/opentrace) server over HTTP.

> **OpenTrace Server** -- This gem requires a running [OpenTrace server](https://github.com/adham90/opentrace). OpenTrace is a self-hosted observability tool for logs, database monitoring, and intelligent alerting. See the [server repo](https://github.com/adham90/opentrace) for setup instructions.

**This gem will never crash or slow down your application.** All network errors are swallowed silently. If the server is unreachable, logs are dropped -- your app continues running normally.

## Features

- **Zero-risk integration** -- all errors swallowed, never raises to host app
- **Async dispatch** -- logs are queued in-memory and sent via a background thread
- **Batch sending** -- groups logs into configurable batches for efficient network usage
- **Bounded queue** -- caps at 1,000 entries to prevent memory bloat
- **Smart truncation** -- oversized payloads are truncated instead of silently dropped
- **Works with any server** -- Puma (threads), Unicorn (forks), Passenger, and Falcon (fibers)
- **Fork safe** -- detects forked worker processes and re-initializes cleanly
- **Fiber safe** -- uses `Fiber[]` storage for correct request isolation in fiber-based servers
- **Rails integration** -- auto-instruments controllers, SQL queries, ActiveJob, views, cache, and more
- **Rack middleware** -- propagates `request_id` via fiber-local storage
- **Logger wrapper** -- drop-in replacement that forwards to OpenTrace while keeping your original logger
- **Rails 7.1+ BroadcastLogger** -- native support via `broadcast_to`
- **TaggedLogging** -- preserves `ActiveSupport::TaggedLogging` tags in metadata
- **Context support** -- attach global metadata to every log via Hash or Proc
- **Level filtering** -- `min_level` config to control which severities are forwarded
- **Auto-enrichment** -- every log includes `hostname`, `pid`, and `git_sha` automatically
- **Exception helper** -- `OpenTrace.error` captures class, message, cleaned backtrace, and error fingerprint
- **Runtime controls** -- enable/disable logging at runtime without restarting
- **Graceful shutdown** -- pending logs are flushed automatically on process exit
- **N+1 query detection** -- warns when a request exceeds 20 SQL queries
- **Per-request summary** -- one rich log per request with SQL, view, cache breakdown and timeline
- **Error fingerprinting** -- stable fingerprint for grouping identical errors across requests
- **Deprecation tracking** -- captures Rails deprecation warnings with callsite
- **DB pool monitoring** -- background thread reports connection pool saturation (opt-in)
- **Job queue depth** -- monitors Sidekiq, GoodJob, or SolidQueue queue sizes (opt-in)
- **Memory delta tracking** -- snapshots process RSS before/after each request (opt-in)
- **External HTTP tracking** -- captures outbound Net::HTTP calls with timing (opt-in)

## Installation

Add to your Gemfile:

```ruby
gem "opentrace"
```

Then run:

```bash
bundle install
```

Or install directly:

```bash
gem install opentrace
```

## Quick Start

```ruby
OpenTrace.configure do |c|
  c.endpoint = "https://opentrace.example.com"
  c.api_key  = ENV["OPENTRACE_API_KEY"]
  c.service  = "my-app"
end

OpenTrace.log("INFO", "User signed in", { user_id: 42 })
```

That's it. Logs are queued and sent asynchronously -- your code never blocks.

## Configuration

```ruby
OpenTrace.configure do |c|
  # Required
  c.endpoint    = "https://opentrace.example.com"
  c.api_key     = ENV["OPENTRACE_API_KEY"]
  c.service     = "billing-api"

  # Optional
  c.environment = "production"           # default: nil
  c.timeout     = 1.0                    # HTTP timeout in seconds (default: 1.0)
  c.enabled     = true                   # default: true
  c.min_level   = :info                  # minimum level to forward (default: :debug)
  c.batch_size  = 50                     # logs per batch (default: 50)
  c.flush_interval = 5.0                 # seconds between flushes (default: 5.0)

  # Global context -- attached to every log entry
  c.context = { deploy_version: "v1.2.3" }
  # Or use a Proc for dynamic context:
  c.context = -> { { tenant_id: Current.tenant&.id } }

  # Auto-populated (override if needed)
  c.hostname = Socket.gethostname        # auto-detected
  c.pid      = Process.pid               # auto-detected
  c.git_sha  = ENV["REVISION"]           # checks REVISION, GIT_SHA, HEROKU_SLUG_COMMIT

  # SQL logging (Rails only)
  c.sql_logging = true                   # default: true
  c.sql_duration_threshold_ms = 100.0    # only log queries slower than this (default: 0.0 = all)

  # Path filtering
  c.ignore_paths = ["/health", %r{\A/assets/}]  # skip noisy paths (default: [])

  # Per-request summary (Rails only)
  c.request_summary = true               # accumulate events into one rich log (default: true)
  c.timeline = true                      # include event timeline in summary (default: true)
  c.timeline_max_events = 200            # cap timeline entries (default: 200)

  # Background monitors (opt-in)
  c.pool_monitoring = false              # DB connection pool stats (default: false)
  c.pool_monitoring_interval = 30        # seconds between checks (default: 30)
  c.queue_monitoring = false             # job queue depth monitoring (default: false)
  c.queue_monitoring_interval = 60       # seconds between checks (default: 60)

  # Advanced opt-in features
  c.memory_tracking = false              # RSS delta per request (default: false)
  c.http_tracking = false                # external HTTP call tracking (default: false)
end
```

If any required field (`endpoint`, `api_key`, `service`) is missing or empty, the gem **disables itself automatically**. No errors, no logs sent.

### Level Filtering

Control which log levels are forwarded with `min_level`:

```ruby
OpenTrace.configure do |c|
  # ...
  c.min_level = :warn  # only forward WARN, ERROR, and FATAL
end
```

Available levels: `:debug`, `:info`, `:warn`, `:error`, `:fatal`

## Usage

### Direct Logging

```ruby
OpenTrace.log("INFO", "User signed in", { user_id: 42, ip: "1.2.3.4" })

OpenTrace.log("ERROR", "Payment failed", {
  trace_id: "abc-123",
  user_id: 99,
  exception: {
    class: "Stripe::CardError",
    message: "Your card was declined"
  }
})
```

Pass `trace_id` inside metadata and it will be promoted to a top-level field automatically.

### Exception Logging

Use `OpenTrace.error` to log exceptions with automatic class, message, backtrace, and fingerprint extraction:

```ruby
begin
  dangerous_operation
rescue => e
  OpenTrace.error(e, { user_id: current_user.id, action: "checkout" })
end
```

This captures:
- `exception_class` -- the exception class name
- `exception_message` -- truncated to 500 characters
- `backtrace` -- cleaned (Rails backtrace cleaner or gem-filtered), limited to 15 frames
- `error_fingerprint` -- 12-char hash for grouping identical errors (stable across line number changes)

### Logger Wrapper

Wrap any Ruby `Logger` to forward all log output to OpenTrace while keeping the original logger working exactly as before:

```ruby
require "logger"

logger = Logger.new($stdout)
logger = OpenTrace::Logger.new(logger)

logger.info("This goes to STDOUT and to OpenTrace")
logger.error("So does this")
```

Attach default metadata to every log from this logger:

```ruby
logger = OpenTrace::Logger.new(original_logger, metadata: { component: "worker" })
logger.info("Processing job")
# metadata: { component: "worker" }
```

### Global Context

Attach metadata to **every** log entry using `config.context`:

```ruby
# Static context
OpenTrace.configure do |c|
  # ...
  c.context = { deploy_version: "v1.2.3", region: "us-east-1" }
end

# Dynamic context (evaluated on each log call)
OpenTrace.configure do |c|
  # ...
  c.context = -> { { tenant: Current.tenant&.slug } }
end
```

Context has the lowest priority -- caller-provided metadata overrides context values.

## Rails Integration

In a Rails app, add an initializer:

```ruby
# config/initializers/opentrace.rb
OpenTrace.configure do |c|
  c.endpoint    = ENV["OPENTRACE_ENDPOINT"]
  c.api_key     = ENV["OPENTRACE_API_KEY"]
  c.service     = "my-rails-app"
  c.environment = Rails.env
end
```

The gem auto-detects Rails and provides the following integrations automatically:

### Rack Middleware

Automatically inserted into the middleware stack. Captures `request_id` from `action_dispatch.request_id` or `HTTP_X_REQUEST_ID` and makes it available via `OpenTrace.current_request_id`. All logs within a request automatically include the `request_id`.

Request IDs are stored using `Fiber[]` (fiber-local storage), which works correctly in both threaded servers (Puma) and fiber-based servers (Falcon).

### Logger Wrapping

- **Rails 7.1+**: Uses `BroadcastLogger#broadcast_to` to register as a broadcast target (non-invasive)
- **Pre-7.1**: Wraps `Rails.logger` with `OpenTrace::Logger` which delegates to the original and forwards to OpenTrace

All your existing `Rails.logger.info(...)` calls automatically get forwarded to OpenTrace.

### Per-Request Summary

When `request_summary` is enabled (the default), the gem accumulates all events during a request -- SQL queries, view renders, cache operations, HTTP calls -- into a single rich log entry emitted at request end. This avoids flooding the queue with hundreds of individual events.

Example payload:

```json
{
  "level": "INFO",
  "message": "GET /dashboard 200 2847ms",
  "metadata": {
    "request_id": "req-abc123",
    "controller": "DashboardController",
    "action": "index",
    "method": "GET",
    "path": "/dashboard",
    "status": 200,
    "duration_ms": 2847.3,

    "request_user_agent": "Mozilla/5.0...",
    "request_accept": "text/html",

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
      { "t": "cache", "a": "read", "hit": true, "ms": 0.1, "at": 6.0 },
      { "t": "sql", "n": "Order Count", "ms": 312.0, "at": 10.0 },
      { "t": "view", "n": "dashboard/index.html.erb", "ms": 890.2, "at": 350.0 }
    ]
  }
}
```

The timeline shows a waterfall of events in chronological order. Timeline keys are kept short to minimize payload size: `t` = type, `n` = name, `ms` = duration, `at` = offset from request start, `s` = status, `a` = action.

### Controller Subscriber

Subscribes to `process_action.action_controller` and captures:

| Field | Description |
|---|---|
| `request_id` | From ActionDispatch |
| `controller` | Controller class name |
| `action` | Action name |
| `method` | HTTP method (GET, POST, etc.) |
| `path` | Request path |
| `status` | HTTP response status code |
| `duration_ms` | Request duration in milliseconds |
| `user_id` | Auto-captured if controller responds to `current_user` |
| `params` | Filtered request parameters (respects `filter_parameters`) |
| `exception_class` | Exception class (if raised) |
| `exception_message` | Exception message (if raised) |
| `backtrace` | Cleaned backtrace (if exception raised) |
| `error_fingerprint` | 12-char fingerprint for error grouping |
| `request_content_type` | Request Content-Type header |
| `request_accept` | Request Accept header |
| `request_user_agent` | Request User-Agent (truncated to 200 chars) |
| `request_referer` | Request Referer header |
| `sql_query_count` | Total SQL queries in this request |
| `sql_total_ms` | Total SQL time in this request |
| `n_plus_one_warning` | `true` when query count exceeds 20 |

When request summary is enabled, the log also includes view render stats, cache stats, time breakdown, and timeline (see above).

Log levels are set automatically:
- **ERROR** -- exceptions or 5xx status
- **WARN** -- 4xx status
- **INFO** -- everything else

### N+1 Query Detection

Every request tracks the number of SQL queries via a Fiber-local counter. When a request exceeds 20 queries, the log entry includes `n_plus_one_warning: true`. This makes it easy to query OpenTrace for requests with potential N+1 issues.

### SQL Query Subscriber

Subscribes to `sql.active_record` and logs every query with:

| Field | Description |
|---|---|
| `sql_name` | Query name (e.g., "User Load") |
| `sql` | Query text (truncated to 1000 chars) |
| `sql_duration_ms` | Query duration in milliseconds |
| `sql_cached` | Whether the result was cached |
| `sql_table` | Extracted table name for filtering |

SCHEMA queries (migrations, structure dumps) are automatically skipped. Queries over 1 second are logged as `WARN`, all others as `DEBUG`.

Configure SQL logging:

```ruby
OpenTrace.configure do |c|
  # ...
  c.sql_logging = true                  # enable/disable (default: true)
  c.sql_duration_threshold_ms = 100.0   # only log slow queries (default: 0.0 = all)
end
```

### ActiveJob Subscriber

Subscribes to `perform.active_job` and logs every job execution with:

| Field | Description |
|---|---|
| `job_class` | Job class name |
| `job_id` | Unique job ID |
| `queue_name` | Queue the job ran on |
| `executions` | Attempt number |
| `duration_ms` | Execution duration |
| `job_arguments` | Serialized arguments (truncated to 512 bytes) |
| `queue_latency_ms` | Time spent waiting in queue before execution |
| `enqueued_at` | When the job was enqueued |
| `exception_class` | Exception class (if failed) |
| `exception_message` | Exception message (if failed) |
| `backtrace` | Cleaned backtrace (if failed) |
| `error_fingerprint` | Fingerprint for error grouping (if failed) |

Failed jobs are logged as `ERROR`, successful jobs as `INFO`.

### Deprecation Warning Subscriber

Subscribes to `deprecation.rails` and logs all Rails deprecation warnings as `WARN`:

| Field | Description |
|---|---|
| `deprecation_message` | The deprecation message (truncated to 500 chars) |
| `deprecation_callsite` | File and line where the deprecated API was called |
| `request_id` | Current request ID (if in web context) |

### View Render Tracking

When request summary is enabled, subscribes to `render_template.action_view` and `render_partial.action_view`. View render events are accumulated in the RequestCollector and included in the per-request summary -- **no individual log entries are emitted** for views.

The summary includes:
- `view_render_count` -- total number of templates/partials rendered
- `view_total_ms` -- total rendering time
- `view_slowest_ms` / `view_slowest_template` -- the bottleneck template

Template paths are automatically shortened (e.g., `/Users/deploy/app/views/orders/show.html.erb` becomes `orders/show.html.erb`).

### Cache Operation Tracking

When request summary is enabled, subscribes to `cache_read.active_support`, `cache_write.active_support`, and `cache_delete.active_support`. Like views, cache events are accumulated -- no individual logs.

The summary includes:
- `cache_reads` / `cache_hits` / `cache_writes`
- `cache_hit_ratio` -- hit rate (0.0 to 1.0)

### Error Fingerprinting

Every error (in controller requests, job failures, and `OpenTrace.error` calls) includes an `error_fingerprint` -- a 12-character hash derived from the exception class and the first application frame in the backtrace. The fingerprint is:

- **Stable across deploys** -- line number changes don't affect it
- **Same error, same fingerprint** -- different error messages at the same location produce the same fingerprint
- **Different error, different fingerprint** -- different exception classes or different code locations produce different fingerprints

Use it to group and count errors in OpenTrace.

### TaggedLogging

If your wrapped logger uses `ActiveSupport::TaggedLogging`, tags are preserved and injected into the metadata:

```ruby
Rails.logger.tagged("RequestID-123", "UserID-42") do
  Rails.logger.info("Processing request")
  # metadata: { tags: ["RequestID-123", "UserID-42"] }
end
```

## Background Monitors

### DB Connection Pool Monitoring

Opt-in background thread that periodically reports ActiveRecord connection pool stats:

```ruby
OpenTrace.configure do |c|
  # ...
  c.pool_monitoring = true
  c.pool_monitoring_interval = 30  # seconds (default: 30)
end
```

Reports `pool_size`, `connections_busy`, `connections_idle`, `threads_waiting`, and `checkout_timeout`. Logs at `WARN` when threads are waiting for a connection, `DEBUG` otherwise.

### Job Queue Depth Monitoring

Opt-in background thread that reports job queue sizes. Supports Sidekiq, GoodJob, and SolidQueue (auto-detected):

```ruby
OpenTrace.configure do |c|
  # ...
  c.queue_monitoring = true
  c.queue_monitoring_interval = 60  # seconds (default: 60)
end
```

Reports per-queue sizes and total enqueued count. Logs at `WARN` when total exceeds 1,000.

## Advanced Opt-In Features

These features have measurable overhead or implementation risks. **Disabled by default.** Enable them after testing in staging.

### Memory Delta Tracking

Snapshots process memory (RSS) before and after each request:

```ruby
OpenTrace.configure do |c|
  # ...
  c.memory_tracking = true
end
```

Adds to the request summary:
- `memory_before_mb` -- RSS before request
- `memory_after_mb` -- RSS after request
- `memory_delta_mb` -- difference (positive = memory grew)

Uses `/proc/self/statm` on Linux (~10us) or `GC.stat` approximation on macOS (~5us). The delta is process-level, so concurrent requests will affect accuracy. Most accurate on single-threaded servers (Unicorn).

### External HTTP Tracking

Instruments outbound `Net::HTTP` calls to capture third-party API performance:

```ruby
OpenTrace.configure do |c|
  # ...
  c.http_tracking = true
end
```

Adds to the request summary:
- `http_external_count` -- number of outbound HTTP calls
- `http_external_total_ms` -- total time in external calls
- `http_slowest_ms` / `http_slowest_host` -- the bottleneck

Each HTTP call appears in the timeline:

```json
{ "t": "http", "n": "POST api.stripe.com", "ms": 184.0, "s": 200, "at": 55.0 }
```

Failed calls include an error type:

```json
{ "t": "http", "n": "POST api.stripe.com", "ms": 5200.0, "s": 0, "err": "Net::ReadTimeout", "at": 55.0 }
```

A recursion guard prevents OpenTrace's own HTTP calls to the server from being tracked. The `time_breakdown` in the request summary includes `http_pct` alongside `sql_pct` and `view_pct`.

**Note**: This works by prepending a module to `Net::HTTP`. Libraries that use `Net::HTTP` internally (Faraday, HTTParty, RestClient) are automatically captured.

## Runtime Controls

```ruby
OpenTrace.enabled?  # check if logging is active
OpenTrace.disable!  # turn off (logs are silently dropped)
OpenTrace.enable!   # turn back on
```

## Graceful Shutdown

An `at_exit` hook is registered automatically to flush pending logs (up to 2 seconds) when the process exits. No configuration needed.

For manual control (e.g. a Sidekiq worker), you can drain the queue explicitly:

```ruby
OpenTrace.shutdown(timeout: 5)
```

This gives the background thread up to 5 seconds to send any remaining queued logs.

## Server Compatibility

OpenTrace works with any Rack-compatible Ruby web server:

| Server | Concurrency | Support |
|---|---|---|
| **Puma** | Threads | Full support |
| **Unicorn** | Forked workers | Full support (fork-safe) |
| **Passenger** | Forks + threads | Full support (fork-safe) |
| **Falcon** | Fibers | Full support (fiber-safe) |

**Fork safety**: When a process forks (Puma cluster mode, Unicorn, Passenger), the background dispatch thread from the parent is dead in the child. OpenTrace detects the fork via PID check and cleanly re-initializes the queue, mutex, and thread.

**Fiber safety**: Request IDs use `Fiber[]` storage instead of `Thread.current`, so concurrent requests on the same thread (as in Falcon) are correctly isolated.

## How It Works

```
Your App --log()--> [In-Memory Queue] --background thread--> POST /api/logs --> OpenTrace Server
```

- Logs are serialized to JSON and pushed onto an in-memory queue
- A single background thread reads from the queue and sends batches via `POST /api/logs`
- `enqueue` is non-blocking -- it uses `try_lock` so it never waits on a mutex
- The thread is started lazily on the first log call -- no threads are created at boot
- If the queue exceeds 1,000 items, new logs are dropped (oldest are preserved)
- Payloads exceeding 32 KB are intelligently truncated (backtrace, params, SQL removed first)
- If still too large after truncation, the payload is split and retried in smaller batches
- All network errors (timeouts, connection refused, DNS failures) are swallowed silently
- The HTTP timeout defaults to 1 second
- Pending logs are flushed on process exit via an `at_exit` hook

### Request Summary Architecture

When `request_summary` is enabled, events within a request are **accumulated** in a Fiber-local `RequestCollector` instead of being pushed to the queue individually:

```
Request Start
  Middleware creates RequestCollector in Fiber[]
    SQL events ──► collector.record_sql()      (no queue push)
    View events ──► collector.record_view()    (no queue push)
    Cache events ──► collector.record_cache()  (no queue push)
    HTTP events ──► collector.record_http()    (no queue push)
  Request End
    Controller subscriber merges collector.summary() into one log
    One queue push with everything
  Middleware cleans up RequestCollector
```

This means a request with 30 SQL queries, 50 view renders, and 10 cache operations produces **one log entry** instead of 91.

## Log Payload Format

Each log is sent as a JSON object to `POST /api/logs`:

```json
{
  "timestamp": "2026-02-08T12:41:00.000000Z",
  "level": "ERROR",
  "service": "billing-api",
  "environment": "production",
  "trace_id": "abc-123",
  "message": "PG::UniqueViolation",
  "metadata": {
    "user_id": 42,
    "request_id": "req-456",
    "hostname": "web-01",
    "pid": 12345,
    "git_sha": "a1b2c3d"
  }
}
```

| Field | Type | Required |
|---|---|---|
| `timestamp` | string (ISO 8601) | yes |
| `level` | string | yes |
| `message` | string | yes |
| `service` | string | no |
| `environment` | string | no |
| `trace_id` | string | no |
| `metadata` | object | no |

The server accepts a single JSON object or an array of objects.

## Requirements

- Ruby >= 3.2 (uses `Fiber[]` for fiber-local storage)
- Rails >= 6 (optional, auto-detected)

## License

[MIT](LICENSE)
