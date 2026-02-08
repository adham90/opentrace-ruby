# OpenTrace Ruby

A thin, safe Ruby client that forwards structured application logs to an [OpenTrace](https://github.com/opentrace/opentrace) server over HTTP.

**This gem will never crash or slow down your application.** All network errors are swallowed silently. If the server is unreachable, logs are dropped.

## Installation

Add to your Gemfile:

```ruby
gem "opentrace"
```

Then run:

```bash
bundle install
```

## Configuration

```ruby
OpenTrace.configure do |c|
  c.endpoint    = "https://opentrace.example.com"   # required
  c.api_key     = ENV["OPENTRACE_API_KEY"]           # required
  c.service     = "billing-api"                      # required
  c.environment = "production"                       # optional
  c.timeout     = 1.0                                # optional, seconds (default: 1.0)
  c.enabled     = true                               # optional (default: true)
end
```

If any required field (`endpoint`, `api_key`, `service`) is missing or empty, the gem **disables itself automatically**. No errors, no logs sent.

## Usage

### Direct logging

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

### Logger wrapper

Wrap any Ruby `Logger` to forward all log output to OpenTrace while keeping the original logger working exactly as before:

```ruby
require "logger"

logger = Logger.new($stdout)
logger = OpenTrace::Logger.new(logger)

logger.info("This goes to STDOUT and to OpenTrace")
logger.error("So does this")
```

You can attach default metadata to every log from this logger:

```ruby
logger = OpenTrace::Logger.new(original_logger, metadata: { component: "worker" })
```

### Rails

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

The gem auto-detects Rails and will:

- Wrap `Rails.logger` so all log output is forwarded to OpenTrace
- Subscribe to `process_action.action_controller` notifications to capture:
  - `request_id`
  - `controller` and `action`
  - `method`, `path`, `status`, `duration_ms`
  - `user_id` (if your controller responds to `current_user`)

Requests that return 5xx status codes are logged as `ERROR`, everything else as `INFO`.

### TaggedLogging

If your wrapped logger uses `ActiveSupport::TaggedLogging`, tags are preserved and injected into the metadata:

```ruby
Rails.logger.tagged("RequestID-123") do
  Rails.logger.info("Processing request")
  # metadata will include: { tags: ["RequestID-123"] }
end
```

## Runtime controls

```ruby
OpenTrace.enabled?  # check if logging is active
OpenTrace.disable!  # turn off (logs are silently dropped)
OpenTrace.enable!   # turn back on
```

## Graceful shutdown

If your app needs a clean shutdown (e.g. a Sidekiq worker), drain the queue before exiting:

```ruby
OpenTrace.shutdown(timeout: 5)
```

This gives the background thread up to 5 seconds to send any remaining queued logs.

## How it works

- Logs are serialized to JSON and pushed onto an in-memory queue
- A single background thread reads from the queue and sends each payload via `POST /api/logs`
- The thread is started lazily on the first log call -- no threads are created at boot
- If the queue exceeds 1,000 items, new logs are dropped (oldest are preserved)
- Payloads larger than 32 KB are dropped
- All network errors (timeouts, connection refused, DNS failures) are swallowed silently
- The HTTP timeout defaults to 1 second

## Log payload format

Each log is sent as a JSON object:

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
    "request_id": "req-456"
  }
}
```

| Field         | Type   | Required |
|---------------|--------|----------|
| `timestamp`   | string | yes      |
| `level`       | string | yes      |
| `message`     | string | yes      |
| `service`     | string | no       |
| `environment` | string | no       |
| `trace_id`    | string | no       |
| `metadata`    | object | no       |

## Requirements

- Ruby 3.0+
- Rails 6+ (optional, auto-detected)

## License

MIT
