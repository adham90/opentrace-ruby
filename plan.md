# 📦 OpenTrace Ruby Gem – MVP Engineering Plan

**Purpose**
Provide a **thin, safe Ruby client** that forwards structured application logs to an OpenTrace server over HTTP.
The gem must *never* affect application behavior or uptime.

> **Guiding Principle:** This gem is plumbing, not intelligence. It ships logs reliably and quietly.

---

## 1. Non‑Goals (Strict)

* No agent logic
* No embeddings
* No database access
* No retries with exponential backoff
* No guaranteed delivery semantics
* No bidirectional communication

If the OpenTrace server is unavailable, **logs must be dropped silently** after a short timeout.

---

## 2. Compatibility Targets

* Ruby **3.0+**
* Rails **6+** (optional, auto-detected)
* Works in non‑Rails Ruby apps

---

## 3. Installation

```ruby
# Gemfile
gem "opentrace"
```

```bash
bundle install
```

---

## 4. Configuration API

```ruby
OpenTrace.configure do |c|
  c.endpoint        = "https://opentrace.internal"   # required
  c.api_key         = ENV["OPENTRACE_API_KEY"]       # required
  c.service         = "billing-api"                  # required
  c.environment     = Rails.env rescue "production"
  c.timeout         = 1.0                              # seconds
  c.enabled         = true
end
```

### Required Config

* `endpoint`
* `api_key`
* `service`

If any required field is missing, the gem **disables itself automatically**.

---

## 5. Log Payload Contract

Each log event is sent as a single JSON object:

```json
{
  "timestamp": "2026-02-08T12:41:00Z",
  "level": "ERROR",
  "service": "billing-api",
  "environment": "production",
  "trace_id": "abc123",
  "message": "PG::UniqueViolation",
  "metadata": {
    "request_id": "req-123",
    "user_id": 42,
    "exception": {
      "class": "PG::UniqueViolation",
      "message": "duplicate key value",
      "backtrace": ["..."]
    }
  }
}
```

**Notes**:

* `trace_id` is optional
* `metadata` must always be a JSON object
* Payload size should be < 32 KB

---

## 6. Transport Layer

* **Protocol**: HTTP

* **Method**: `POST`

* **Path**: `/api/logs`

* **Headers**:

  ```
  Authorization: Bearer <api_key>
  Content-Type: application/json
  User-Agent: opentrace-ruby/<version>
  ```

* **Timeout**: Hard cutoff at `timeout` seconds

* **Failure behavior**: Swallow all network errors

---

## 7. Logger Integration

### A. Drop‑in Logger Wrapper

```ruby
Rails.logger = OpenTrace::Logger.new(Rails.logger)
```

Behavior:

* Forwards log to OpenTrace
* Delegates synchronously to the wrapped logger
* Never raises

---

### B. ActiveSupport::TaggedLogging Support

* Preserve tags
* Inject tags into `metadata[:tags]`

---

## 8. Rails Auto‑Integration (Optional)

If Rails is detected:

* Auto‑hook `Rails.logger`
* Capture:

  * request ID
  * controller / action
  * current user ID (if present)

All Rails hooks must be:

* lazy‑loaded
* behind `if defined?(Rails)` checks

---

## 9. Async Dispatch Model

* Use a background thread with a `Queue`
* Max queue size: **1000 messages**
* If queue is full → **drop newest log**
* Thread started lazily on first log

No threads created at boot.

---

## 10. Public API Surface

```ruby
OpenTrace.log(level, message, metadata = {})
OpenTrace.enabled?
OpenTrace.disable!
OpenTrace.enable!
```

No other public APIs.

---

## 11. File Layout

```
opentrace/
├── lib/
│   ├── opentrace.rb
│   ├── opentrace/config.rb
│   ├── opentrace/client.rb
│   ├── opentrace/logger.rb
│   └── opentrace/rails.rb
├── opentrace.gemspec
└── README.md
```

---

## 12. Safety Guarantees (Hard Rules)

* Never raise exceptions to the host app
* Never block the request thread longer than `timeout`
* Never log to STDOUT by default
* Never mutate log messages
* Never depend on Rails internals directly

---

## 13. Testing Strategy

* Unit tests only (no network calls)
* Mock HTTP client
* Test cases:

  * disabled config
  * missing API key
  * network failure
  * queue overflow
  * logger delegation

RSpec preferred, Minitest acceptable.

---

## 14. Release Strategy

* Version `0.1.0` = logs only
* No breaking changes before `1.0`
* Semantic versioning
* Publish to RubyGems

---

## Final Rule

> **If this gem can crash or slow down the host app, the implementation is wrong.**

Quiet. Safe. Predictable. That is the entire job of this gem.
