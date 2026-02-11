# OpenTrace Ruby

[![Gem Version](https://badge.fury.io/rb/opentrace.svg)](https://rubygems.org/gems/opentrace)
[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)

A thin, safe Ruby client that forwards structured application logs to an [OpenTrace](https://github.com/adham90/opentrace-ruby) server over HTTP.

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
- **Rails integration** -- auto-instruments controllers, SQL queries, and ActiveJob via Railtie
- **Rack middleware** -- propagates `request_id` via fiber-local storage
- **Logger wrapper** -- drop-in replacement that forwards to OpenTrace while keeping your original logger
- **Rails 7.1+ BroadcastLogger** -- native support via `broadcast_to`
- **TaggedLogging** -- preserves `ActiveSupport::TaggedLogging` tags in metadata
- **Context support** -- attach global metadata to every log via Hash or Proc
- **Level filtering** -- `min_level` config to control which severities are forwarded
- **Auto-enrichment** -- every log includes `hostname`, `pid`, and `git_sha` automatically
- **Exception helper** -- `OpenTrace.error` captures class, message, and cleaned backtrace
- **Runtime controls** -- enable/disable logging at runtime without restarting
- **Graceful shutdown** -- pending logs are flushed automatically on process exit

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

Use `OpenTrace.error` to log exceptions with automatic class, message, and backtrace extraction:

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

Log levels are set automatically:
- **ERROR** -- exceptions or 5xx status
- **WARN** -- 4xx status
- **INFO** -- everything else

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
| `exception_class` | Exception class (if failed) |
| `exception_message` | Exception message (if failed) |
| `backtrace` | Cleaned backtrace (if failed) |

Failed jobs are logged as `ERROR`, successful jobs as `INFO`.

### TaggedLogging

If your wrapped logger uses `ActiveSupport::TaggedLogging`, tags are preserved and injected into the metadata:

```ruby
Rails.logger.tagged("RequestID-123", "UserID-42") do
  Rails.logger.info("Processing request")
  # metadata: { tags: ["RequestID-123", "UserID-42"] }
end
```

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
