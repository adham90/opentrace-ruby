# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [0.15.1] - 2026-02-16

### Changed

- **Indexed field promotion**: Promote `commit_hash`, `request_id`, `exception_class`, `error_fingerprint`, `source_file`, and `source_line` from metadata to top-level payload keys for fast B-tree lookups on the server

## [0.15.0] - 2026-02-14

### Added

- **Sample rate validation**: `config.sample_rate=` validates values are in `0.0..1.0` range; raises `ArgumentError` on invalid values
- **NilStats caching**: `NilClient` caches a single `@nil_stats` instance instead of allocating on every `.stats` call

### Changed

- **Middleware refactoring**: Extract Fiber-local keys into `FIBER_KEYS` constant with centralized `cleanup_fiber_locals` method to prevent missed keys when new Fiber state is added

### Fixed

- **Thread safety**: Wrap `Stats#increment` counter mutations in `@mutex.synchronize`
- **Socket timeout**: Add `IO.select` with 5-second timeout to `unix_socket_send` to prevent indefinite blocking on unresponsive Unix sockets
- **Error visibility**: `PayloadBuilder` now increments error stats on failures and logs to stderr in debug mode

## [0.14.1] - 2026-02-14

### Fixed

- **Circuit breaker recovery**: `HALF_OPEN` state could reject all concurrent probe requests, preventing circuit recovery. Now correctly allows exactly one probe request through
- **Unix socket require**: Add lazy `require "socket"` in `unix_socket_send` to prevent `NameError` when `UNIXSocket` is used but socket library isn't loaded
- **Queue race condition**: `ClosedQueueError` race in `handle_rate_limit` where queue closure during re-enqueue silently dropped remaining batch items

## [0.14.0] - 2026-02-14

### Fixed

- **Drain queue busy-spin (critical)**: `drain_queue` held the GIL continuously, starving all request fibers in Falcon workers for ~5 seconds. After receiving the first queue item, the method switched to non-blocking pops in a tight loop until the `flush_interval` deadline. Fix: always use blocking pop (capped at 0.5s via `MAX_POP_WAIT`) when queue is empty, releasing the GIL between checks. Every request now takes ~10ms instead of ~5000ms
- Cache `enabled?` and `level_allowed?` calls to avoid per-request recomputation
- Early level check in `forward_sql_log` to skip regex/hash computation when filtered
- Cache EXPLAIN config values at subscribe time to reduce overhead

## [0.13.2] - 2026-02-14

### Fixed

- **TaggedLogging completeness**: Add missing `clear_tags!` and `tags_text` methods to `TraceFormatter` and `LogForwarder`. `TaggedLogging` delegates these during log flush and shutdown — missing methods caused crashes even after the v0.13.1 fix
- Add real integration tests using actual `BroadcastLogger` and `TaggedLogging` classes

## [0.13.1] - 2026-02-14

### Fixed

- **TaggedLogging interface**: Fix `NoMethodError: push_tags` crash on every request when `Rails::Rack::Logger` calls `push_tags` on `BroadcastLogger`. `TraceFormatter` now delegates `push_tags`, `pop_tags`, `current_tags`, and `tagged` to the wrapped original formatter. `LogForwarder` implements these as no-ops

## [0.13.0] - 2026-02-13

### Added

- **PII regex fixes**: Improved accuracy of credit card, SSN, and phone number patterns to reduce false positives
- **Batch split recursion guard**: Prevent infinite recursion when splitting oversized batches

### Security

- **Sensitive variable filtering**: Filter local variable names matching `password`, `token`, `api_key`, etc., replacing values with `[FILTERED]`
- **Path traversal prevention**: Use `File.realpath` + `Rails.root` verification to prevent symlink attacks when reading source code context
- **EXPLAIN SQL validation**: Validate SQL is `SELECT`-only before running `EXPLAIN`; reject multi-statement queries
- **URL sanitization**: Strip query parameters from tracked HTTP URLs to avoid logging sensitive values

## [0.12.0] - 2026-02-13

### Added

- **Unix socket transport**: Send logs via Unix socket for co-located deployments (2-5x faster than TCP). Automatic HTTP fallback. Config: `config.transport = :unix_socket`, `config.unix_socket_path`
- **Local variable capture**: `OpenTrace.capture_binding(exception, binding)` snapshots local variables at crash point. Limited to 10 vars, 500 chars each. Sensitive names auto-filtered. ~5μs per call
- **EXPLAIN plan capture**: Automatically runs `EXPLAIN` on slow SQL queries (deferred to background thread). Only for `SELECT` queries. ~1ms per query
- **GC/Runtime metrics**: Background timer collects heap stats, thread count, and process RSS. Config: `config.runtime_metrics = true`, `config.runtime_metrics_interval` (default: 60s)

## [0.11.0] - 2026-02-13

### Added

- **PII scrubbing** (opt-in): Regex patterns detect and redact credit cards, emails, SSNs, phone numbers, bearer tokens, and API keys. Config: `config.pii_scrubbing = true`, `config.pii_patterns`, `config.pii_disabled_patterns`. Runs on background thread
- **Session tracking** (opt-in): Extracts `session_id` from `rack.session` or cookies. Config: `config.session_tracking = true`
- **Duplicate query detection**: Fingerprints SQL queries per request, counts duplicates, attaches to request summary
- **Lifecycle callbacks**: `on_error`, `after_send`, `before_breadcrumb` for custom integrations

## [0.10.0] - 2026-02-13

### Added

- **Custom instrumentation API**: `OpenTrace.trace("operation_name") { block }` creates timed spans with automatic parent/child nesting via Fiber-local span stack. Optional `resource` parameter and `tags`. ~200ns per call
- **Breadcrumbs API**: `OpenTrace.add_breadcrumb(category, message, data: {})` records lightweight events per-request (max 25, FIFO). Breadcrumbs attach to error payloads only. ~100ns per breadcrumb
- **Source code context**: Captures 3 lines above/below error origin. LRU file cache (50 files, 500KB max), reads only `app/`, `lib/`, `config/` paths. Config: `config.source_context = true`

## [0.9.0] - 2026-02-13

### Added

- **Exception cause chaining**: Walks `exception.cause` chain (max 5 deep) and attaches root-cause info to error payloads. ~50ns per error
- **SQL query normalization**: Replaces literals with `?` placeholders for query grouping and PII-safe logging. Runs on background thread
- **Custom transaction naming**: `OpenTrace.set_transaction_name("name")` for Grape/Sinatra and custom endpoint grouping
- **Log trace injection**: `TraceFormatter` injects `[trace_id=xxx request_id=yyy]` prefix into every log line for correlation

## [0.8.0] - 2026-02-12

### Changed

- **All expensive features now opt-in**: Reduces per-request overhead from ~20-70ms to <0.5ms with default config
- New opt-in config flags: `log_forwarding`, `view_tracking`, `cache_tracking`, `deprecation_tracking`, `detailed_request_log`
- Default `sql_logging` changed to `false`
- Default `timeline` changed to `false`
- Default `min_level` changed to `:info`

### Fixed

- Middleware early-returns when `OpenTrace.disabled?` (zero overhead when disabled)
- SQL subscriber uses raw notification args instead of `Event.new` allocation
- `RequestCollector` skips timeline when `max_timeline: 0`
- `extract_user_id` only reads cached context (never calls `controller.current_user`)

## [0.7.0] - 2026-02-12

### Added

- **Retry with exponential backoff**: Failed HTTP requests are retried up to `max_retries` times (default: 2) with jittered exponential backoff
- **Circuit breaker**: Stops sending after `circuit_breaker_threshold` consecutive failures, probes after `circuit_breaker_timeout` seconds
- **Backpressure handling**: Rate-limited responses (429) trigger automatic backoff respecting `Retry-After` header. Auth failures (401) suspend forwarding with a clear STDERR warning
- **Delivery observability**: `OpenTrace.stats` returns counters (enqueued, delivered, dropped, retries, etc.), `OpenTrace.healthy?` health check, `config.on_drop` callback for alerting
- **Gzip compression**: Outgoing batches automatically gzip-compressed when exceeding `compression_threshold` (default: 1KB). Achieves 70-85% bandwidth reduction
- **Batch deduplication**: Each batch gets a unique `X-Batch-ID` header so the server can deduplicate retried requests
- **Structured request metrics**: Performance data (SQL, views, cache, HTTP, memory) sent as a separate `request_summary` field with server-compatible keys for indexed storage
- **Version negotiation**: Client sends `X-API-Version` header, probes `GET /api/version` on first dispatch for capability detection. Warns on version mismatches
- **Configurable payload limit**: Raised default from 32KB to 256KB (`config.max_payload_bytes`), reducing HTTP request count by up to 87% for large batches
- **W3C Trace Context propagation**: Middleware extracts `traceparent`/`X-Trace-ID` from incoming requests, generates `span_id` per request. HttpTracker injects trace context into outgoing HTTP calls
- **Trace fields in payload**: Log entries include `trace_id`, `span_id`, and `parent_span_id` as top-level fields for distributed trace correlation
- `config.trace_propagation` option (default: true) to enable/disable trace context extraction and injection

### Changed

- `request_summary` data is now a separate top-level field instead of being merged into metadata
- Payload size limit raised from 32KB to 256KB (configurable)

## [0.2.1] - 2026-02-11

### Fixed

- **CPU busy-loop fix**: `drain_queue` would spin without sleeping when the queue was idle and the flush deadline expired with an empty batch. With Falcon or any multi-worker server, this caused ~100% CPU per worker.

## [0.2.0] - 2026-02-11

### Added

- **Fork safety**: Detect forked processes (Puma, Unicorn, Passenger) and cleanly re-initialize the background thread, queue, and mutex in child workers
- **Falcon support**: Switch request ID storage from `Thread.current` to `Fiber[]` for correct isolation in fiber-based servers
- **Non-blocking mutex**: Use `try_lock` instead of `synchronize` in thread spawning so `enqueue` never blocks the calling thread
- **Graceful shutdown**: Register an `at_exit` hook to flush pending logs (up to 2s) when the process exits

## [0.1.0] - 2025-02-09

### Added

- Core log forwarding client with async HTTP dispatch and bounded queue (1000 entries)
- Batch sending with configurable `batch_size` and `flush_interval`
- Smart payload truncation instead of silent drop when messages exceed size limits
- `OpenTrace.log` and `OpenTrace.error` convenience methods
- Configuration via `OpenTrace.configure` with auto-disable on missing required fields
- `config.context` support (Hash or Proc) for attaching global metadata to every log
- `config.min_level` filtering to control which severity levels are forwarded
- Auto-populated `hostname`, `pid`, and `git_sha` fields in every log entry
- Rails integration via Railtie:
  - Rack middleware for `request_id` propagation via thread-local
  - Logger wrapping that delegates to the original logger and forwards to OpenTrace
  - Controller subscriber with exception capture, filtered params, and WARN level for 4xx responses
  - SQL query subscriber via `ActiveSupport::Notifications`
  - ActiveJob subscriber via `perform.active_job` notification
- Fix for frozen middleware stack crash on Rails 7.1+
- MIT License

[0.15.1]: https://github.com/adham90/opentrace-ruby/releases/tag/v0.15.1
[0.15.0]: https://github.com/adham90/opentrace-ruby/releases/tag/v0.15.0
[0.14.1]: https://github.com/adham90/opentrace-ruby/releases/tag/v0.14.1
[0.14.0]: https://github.com/adham90/opentrace-ruby/releases/tag/v0.14.0
[0.13.2]: https://github.com/adham90/opentrace-ruby/releases/tag/v0.13.2
[0.13.1]: https://github.com/adham90/opentrace-ruby/releases/tag/v0.13.1
[0.13.0]: https://github.com/adham90/opentrace-ruby/releases/tag/v0.13.0
[0.12.0]: https://github.com/adham90/opentrace-ruby/releases/tag/v0.12.0
[0.11.0]: https://github.com/adham90/opentrace-ruby/releases/tag/v0.11.0
[0.10.0]: https://github.com/adham90/opentrace-ruby/releases/tag/v0.10.0
[0.9.0]: https://github.com/adham90/opentrace-ruby/releases/tag/v0.9.0
[0.8.0]: https://github.com/adham90/opentrace-ruby/releases/tag/v0.8.0
[0.7.0]: https://github.com/adham90/opentrace-ruby/releases/tag/v0.7.0
[0.2.1]: https://github.com/adham90/opentrace-ruby/releases/tag/v0.2.1
[0.2.0]: https://github.com/adham90/opentrace-ruby/releases/tag/v0.2.0
[0.1.0]: https://github.com/adham90/opentrace-ruby/releases/tag/v0.1.0
