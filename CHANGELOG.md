# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

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

[0.2.1]: https://github.com/adham90/opentrace-ruby/releases/tag/v0.2.1
[0.2.0]: https://github.com/adham90/opentrace-ruby/releases/tag/v0.2.0
[0.1.0]: https://github.com/adham90/opentrace-ruby/releases/tag/v0.1.0
