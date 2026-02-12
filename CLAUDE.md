# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What This Is

OpenTrace Ruby — a thin, safety-first async client gem that forwards structured logs to an OpenTrace server over HTTP. The core invariant: **never raise to the host app, never slow it down**. All errors are swallowed, all network calls are async.

Requires Ruby >= 3.2 (uses `Fiber[]`). Only runtime dependency is the `logger` gem.

## Commands

```bash
bundle install                                    # install dependencies
bundle exec rspec                                 # full test suite
bundle exec rspec spec/opentrace/                 # unit tests only
bundle exec rspec spec/integration/               # integration tests only
bundle exec rspec spec/opentrace/client_spec.rb   # single file
bundle exec rspec -e "enqueues a log"             # single example by name
```

Tests use WebMock (no real HTTP). All specs call `OpenTrace.reset!` in before hooks and `OpenTrace.shutdown` in after hooks.

## Architecture

### Data Flow

```
OpenTrace.log() → level filter → context merge → Client#enqueue → Thread::Queue (bounded 1000)
                                                                       ↓
                                                              background thread
                                                                       ↓
                                                            drain_queue (batches)
                                                                       ↓
                                                         POST /api/logs → server
```

### Key Components

- **`OpenTrace` module** (`lib/opentrace.rb`) — Public API (`log`, `error`, `configure`, `enable!`/`disable!`). Manages singleton `Config` and `Client`. All public methods rescue `StandardError`.
- **`Client`** (`lib/opentrace/client.rb`) — Background thread dispatcher. Uses `Thread::Queue` with `try_lock` for non-blocking enqueue. Fork-safe (detects PID change and reinitializes). Splits oversized batches recursively. 32KB payload limit with smart truncation (removes backtrace → params → SQL first).
- **`Middleware`** (`lib/opentrace/middleware.rb`) — Rack middleware. Sets `Fiber[:opentrace_request_id]`, initializes N+1 counter (`Fiber[:opentrace_sql_count]`), and creates `Fiber[:opentrace_collector]` for request summary. All state is Fiber-local for fiber-server (Falcon) compatibility.
- **`RequestCollector`** (`lib/opentrace/request_collector.rb`) — Accumulates SQL/view/cache/HTTP events per request into one rich summary log instead of emitting individual entries. Created in middleware, consumed in the controller subscriber.
- **`Logger`** (`lib/opentrace/logger.rb`) — Wraps any `::Logger`, delegates to original, forwards to OpenTrace. Used pre-Rails 7.1.
- **`LogForwarder`** (`lib/opentrace/log_forwarder.rb`) — Minimal Logger-compatible class for Rails 7.1+ `BroadcastLogger#broadcast_to`. Does not wrap another logger.
- **`Railtie`** (`lib/opentrace/rails.rb`) — Subscribes to `process_action`, `sql.active_record`, `perform.active_job`, `deprecation.rails`, view renders, cache ops via `ActiveSupport::Notifications`. Conditionally loads only when `Rails::Railtie` is defined.
- **`HttpTracker`** (`lib/opentrace/http_tracker.rb`) — Opt-in `Net::HTTP` prepend module. Records outbound HTTP calls into the `RequestCollector`. Uses `Fiber[:opentrace_http_tracking_disabled]` recursion guard to skip OpenTrace's own dispatch calls.
- **`PoolMonitor`** / **`QueueMonitor`** — Opt-in background threads for DB pool and job queue monitoring.

### Fiber-Local State

All per-request state uses `Fiber[]` (not `Thread.current`):

| Key | Purpose |
|---|---|
| `Fiber[:opentrace_request_id]` | Current request ID |
| `Fiber[:opentrace_sql_count]` | N+1 query counter |
| `Fiber[:opentrace_sql_total_ms]` | SQL time accumulator |
| `Fiber[:opentrace_collector]` | RequestCollector instance |
| `Fiber[:opentrace_http_tracking_disabled]` | Recursion guard for HTTP tracker |

### Patterns and Conventions

- Every public-facing method and subscriber block rescues `StandardError` and swallows — no exception may propagate to the host app.
- Config auto-disables when required fields (`endpoint`, `api_key`, `service`) are missing — `enabled?` checks `valid?`.
- `Client#enqueue` uses `Mutex#try_lock` to never block the calling thread.
- Payload truncation order: backtrace → params → job_arguments → SQL → exception_message.
- Error fingerprinting uses MD5 of `"#{exception_class}||#{normalized_origin}"` with line numbers stripped, producing a stable 12-char hex string.
- Test helper `configure_opentrace!` sets `flush_interval: 0.2` for fast test cycles. WebMock stubs `opentrace.test` domain.
