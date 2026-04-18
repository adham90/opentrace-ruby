# frozen_string_literal: true

require "spec_helper"
require "opentrace/request_buffer"

RSpec.describe OpenTrace::RequestBuffer do
  subject(:buffer) { described_class.new(max_buffer_bytes: max_buffer_bytes, max_audit_events: max_audit_events) }

  let(:max_buffer_bytes) { 1_048_576 }
  let(:max_audit_events) { 50 }

  before do
    buffer.id = OpenTrace::ULID.generate
    buffer.started_at = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    buffer.event_type = :http_request
  end

  describe "#record_sql" do
    it "appends to sql_captures" do
      buffer.record_sql(
        raw_sql: "SELECT * FROM users WHERE id = 1",
        normalized_sql: "SELECT * FROM users WHERE id = ?",
        binds: [1],
        duration_ms: 2.5,
        name: "User Load",
        cached: false,
        row_count: 1,
        in_transaction: false,
        fingerprint: "abc123",
        table: "users",
        caller_location: "app/models/user.rb:42"
      )

      expect(buffer.sql_captures.size).to eq(1)
      capture = buffer.sql_captures.first
      expect(capture[:raw_sql]).to eq("SELECT * FROM users WHERE id = 1")
      expect(capture[:normalized_sql]).to eq("SELECT * FROM users WHERE id = ?")
      expect(capture[:duration_ms]).to eq(2.5)
      expect(capture[:name]).to eq("User Load")
      expect(capture[:cached]).to eq(false)
      expect(capture[:table]).to eq("users")
    end

    it "accumulates multiple SQL captures" do
      3.times do |i|
        buffer.record_sql(raw_sql: "SELECT #{i}", duration_ms: i.to_f)
      end
      expect(buffer.sql_captures.size).to eq(3)
    end
  end

  describe "#record_http" do
    it "appends to http_captures" do
      buffer.record_http(
        method: "POST",
        url: "https://api.stripe.com/v1/charges",
        host: "api.stripe.com",
        vendor: "stripe",
        status: 200,
        duration_ms: 150.3,
        request_headers: { "Authorization" => "Bearer sk_test" },
        request_body: '{"amount": 2000}',
        response_headers: { "Content-Type" => "application/json" },
        response_body: '{"id": "ch_123"}',
        response_size: 42,
        retry_attempt: 0,
        error_class: nil
      )

      expect(buffer.http_captures.size).to eq(1)
      capture = buffer.http_captures.first
      expect(capture[:method]).to eq("POST")
      expect(capture[:url]).to eq("https://api.stripe.com/v1/charges")
      expect(capture[:host]).to eq("api.stripe.com")
      expect(capture[:status]).to eq(200)
      expect(capture[:duration_ms]).to eq(150.3)
    end
  end

  describe "#record_email" do
    it "appends to email_captures" do
      buffer.record_email(
        mailer_class: "UserMailer",
        mailer_action: "welcome",
        from: "noreply@example.com",
        to: "user@example.com",
        subject: "Welcome!",
        body_html: "<h1>Welcome</h1>",
        body_text: "Welcome",
        template: "user_mailer/welcome",
        variables: { name: "Alice" },
        attachments: [],
        delivery_status: "sent",
        smtp_response: "250 OK",
        duration_ms: 45.2
      )

      expect(buffer.email_captures.size).to eq(1)
      capture = buffer.email_captures.first
      expect(capture[:mailer_class]).to eq("UserMailer")
      expect(capture[:mailer_action]).to eq("welcome")
      expect(capture[:subject]).to eq("Welcome!")
    end
  end

  describe "#record_audit" do
    it "appends to audit_captures" do
      buffer.record_audit(
        action: "update",
        record_type: "User",
        record_id: 42,
        actor_id: 1,
        actor_type: "Admin",
        changed_fields: { name: ["Alice", "Bob"] },
        full_before: { name: "Alice" },
        full_after: { name: "Bob" }
      )

      expect(buffer.audit_captures.size).to eq(1)
      capture = buffer.audit_captures.first
      expect(capture[:action]).to eq("update")
      expect(capture[:record_type]).to eq("User")
      expect(capture[:record_id]).to eq(42)
    end

    it "respects max_audit_events cap" do
      capped_buffer = described_class.new(max_audit_events: 3)

      5.times do |i|
        capped_buffer.record_audit(action: "update", record_type: "User", record_id: i)
      end

      expect(capped_buffer.audit_captures.size).to eq(3)
    end

    it "sets audit_truncated? after cap is reached" do
      capped_buffer = described_class.new(max_audit_events: 2)

      2.times { |i| capped_buffer.record_audit(action: "update", record_type: "User", record_id: i) }
      expect(capped_buffer.audit_truncated?).to eq(false)

      capped_buffer.record_audit(action: "update", record_type: "User", record_id: 99)
      expect(capped_buffer.audit_truncated?).to eq(true)
    end
  end

  describe "#record_log" do
    it "appends to logs" do
      buffer.record_log(level: "INFO", message: "User signed in", metadata: { user_id: 42 })
      buffer.record_log(level: "WARN", message: "Slow query detected")

      expect(buffer.logs.size).to eq(2)
      expect(buffer.logs.first[:level]).to eq("INFO")
      expect(buffer.logs.first[:message]).to eq("User signed in")
      expect(buffer.logs.first[:metadata]).to eq({ user_id: 42 })
    end
  end

  describe "#record_timeline" do
    it "appends with offset_ms" do
      # started_at is already set in before block (monotonic clock)
      # A small sleep ensures a nonzero offset
      buffer.record_timeline(type: :sql, name: "User Load", duration_ms: 2.5)

      expect(buffer.timeline.size).to eq(1)
      entry = buffer.timeline.first
      expect(entry[:type]).to eq(:sql)
      expect(entry[:name]).to eq("User Load")
      expect(entry[:offset_ms]).to be_a(Float)
      expect(entry[:offset_ms]).to be >= 0.0
      expect(entry[:duration_ms]).to eq(2.5)
    end

    it "merges extra hash into the entry" do
      buffer.record_timeline(type: :http, name: "Stripe API", extra: { status: 200 })

      entry = buffer.timeline.first
      expect(entry[:status]).to eq(200)
    end
  end

  describe "#byte_size" do
    it "returns base estimate when nothing is set" do
      expect(buffer.byte_size).to eq(OpenTrace::RequestBuffer::BASE_BYTE_ESTIMATE)
    end

    it "increases when bodies are set" do
      base = buffer.byte_size

      buffer.request_body = "x" * 5000
      expect(buffer.byte_size).to eq(base + 5000)

      buffer.response_body = "y" * 3000
      expect(buffer.byte_size).to eq(base + 5000 + 3000)
    end

    it "accounts for SQL raw_sql strings" do
      base = buffer.byte_size

      buffer.record_sql(raw_sql: "a" * 1000, duration_ms: 1.0)
      expect(buffer.byte_size).to eq(base + 1000)
    end

    it "accounts for HTTP request/response bodies" do
      base = buffer.byte_size

      buffer.record_http(method: "POST", url: "http://example.com", duration_ms: 10.0,
                         request_body: "b" * 2000, response_body: "c" * 3000)
      expect(buffer.byte_size).to eq(base + 2000 + 3000)
    end

    it "accounts for email bodies" do
      base = buffer.byte_size

      buffer.record_email(mailer_class: "M", mailer_action: "a",
                          body_html: "h" * 1500, body_text: "t" * 500)
      expect(buffer.byte_size).to eq(base + 1500 + 500)
    end

    it "accounts for log messages" do
      base = buffer.byte_size

      buffer.record_log(level: "INFO", message: "m" * 800)
      expect(buffer.byte_size).to eq(base + 800)
    end
  end

  describe "#exceeded_buffer?" do
    it "returns false when under max" do
      expect(buffer.exceeded_buffer?).to eq(false)
    end

    it "returns true when over max" do
      small_buffer = described_class.new(max_buffer_bytes: 2000)
      small_buffer.request_body = "x" * 2000
      # base (1024) + 2000 = 3024 > 2000
      expect(small_buffer.exceeded_buffer?).to eq(true)
    end
  end

  describe "#reset!" do
    it "clears all state" do
      buffer.request_method = "GET"
      buffer.request_path = "/users"
      buffer.request_body = "body"
      buffer.response_body = "resp"
      buffer.controller = "UsersController"
      buffer.action = "index"
      buffer.context = { user_id: 1 }
      buffer.memory_before = 100.0
      buffer.memory_after = 110.0
      buffer.job_class = "SomeJob"

      buffer.record_sql(raw_sql: "SELECT 1", duration_ms: 1.0)
      buffer.record_http(method: "GET", url: "http://x.com", duration_ms: 1.0)
      buffer.record_email(mailer_class: "M", mailer_action: "a")
      buffer.record_file(action: "upload", filename: "test.png")
      buffer.record_audit(action: "create", record_type: "User")
      buffer.record_log(level: "INFO", message: "test")
      buffer.record_timeline(type: :sql, name: "test")

      buffer.reset!

      expect(buffer.id).to be_nil
      expect(buffer.started_at).to be_nil
      expect(buffer.event_type).to be_nil
      expect(buffer.request_method).to be_nil
      expect(buffer.request_path).to be_nil
      expect(buffer.request_body).to be_nil
      expect(buffer.response_body).to be_nil
      expect(buffer.controller).to be_nil
      expect(buffer.action).to be_nil
      expect(buffer.context).to be_nil
      expect(buffer.memory_before).to be_nil
      expect(buffer.memory_after).to be_nil
      expect(buffer.job_class).to be_nil

      expect(buffer.sql_captures).to be_empty
      expect(buffer.http_captures).to be_empty
      expect(buffer.email_captures).to be_empty
      expect(buffer.file_captures).to be_empty
      expect(buffer.audit_captures).to be_empty
      expect(buffer.logs).to be_empty
      expect(buffer.timeline).to be_empty

      expect(buffer.audit_truncated?).to eq(false)
      expect(buffer.byte_size).to eq(OpenTrace::RequestBuffer::BASE_BYTE_ESTIMATE)
    end

    it "keeps arrays allocated (same object_id)" do
      sql_id = buffer.sql_captures.object_id
      http_id = buffer.http_captures.object_id
      logs_id = buffer.logs.object_id

      buffer.record_sql(raw_sql: "SELECT 1", duration_ms: 1.0)
      buffer.reset!

      expect(buffer.sql_captures.object_id).to eq(sql_id)
      expect(buffer.http_captures.object_id).to eq(http_id)
      expect(buffer.logs.object_id).to eq(logs_id)
    end
  end

  describe "#to_document" do
    before do
      buffer.request_method = "POST"
      buffer.request_path = "/api/users"
      buffer.request_headers = { "Content-Type" => "application/json" }
      buffer.request_body = '{"name": "Alice"}'
      buffer.request_params = { name: "Alice" }
      buffer.content_type = "application/json"
      buffer.ip_address = "127.0.0.1"
      buffer.user_agent = "TestAgent/1.0"
      buffer.response_status = 201
      buffer.response_headers = { "X-Request-Id" => "abc" }
      buffer.response_body = '{"id": 1}'
      buffer.response_size = 8
      buffer.controller = "UsersController"
      buffer.action = "create"
      buffer.request_id = "req-123"
      buffer.trace_id = "trace-456"
      buffer.context = { user_id: 42 }
      buffer.memory_before = 100.0
      buffer.memory_after = 110.5

      buffer.record_sql(raw_sql: "INSERT INTO users", normalized_sql: "INSERT INTO users", duration_ms: 3.2, name: "SQL")
      buffer.record_http(method: "POST", url: "https://api.stripe.com/v1/charges", duration_ms: 120.0, request_body: "charge_body", response_body: "charge_resp")
      buffer.record_email(mailer_class: "UserMailer", mailer_action: "welcome", subject: "Hi", body_html: "<p>hi</p>", body_text: "hi")
      buffer.record_log(level: "INFO", message: "User created")
      buffer.record_timeline(type: :sql, name: "INSERT")
    end

    it "produces correct structure with all sections" do
      doc = buffer.to_document(capture_level: :full)

      expect(doc[:id]).to eq(buffer.id)
      expect(doc[:event_type]).to eq(:http_request)
      expect(doc[:started_at]).to be_a(Float)

      # Request section with full bodies
      expect(doc[:request][:method]).to eq("POST")
      expect(doc[:request][:path]).to eq("/api/users")
      expect(doc[:request][:body]).to eq('{"name": "Alice"}')
      expect(doc[:request][:headers]).to eq({ "Content-Type" => "application/json" })
      expect(doc[:request][:params]).to eq({ name: "Alice" })

      # Response section with full bodies
      expect(doc[:response][:status]).to eq(201)
      expect(doc[:response][:body]).to eq('{"id": 1}')
      expect(doc[:response][:headers]).to eq({ "X-Request-Id" => "abc" })

      # Context
      expect(doc[:context]).to eq({ user_id: 42 })
      expect(doc[:controller]).to eq("UsersController")
      expect(doc[:action]).to eq("create")
      expect(doc[:request_id]).to eq("req-123")
      expect(doc[:trace_id]).to eq("trace-456")

      # Performance
      expect(doc[:performance][:memory_before]).to eq(100.0)
      expect(doc[:performance][:memory_after]).to eq(110.5)

      # Domain captures present
      expect(doc[:sql].size).to eq(1)
      expect(doc[:sql].first[:raw_sql]).to eq("INSERT INTO users")
      expect(doc[:http].size).to eq(1)
      expect(doc[:http].first[:request_body]).to eq("charge_body")
      expect(doc[:email].size).to eq(1)
      expect(doc[:email].first[:body_html]).to eq("<p>hi</p>")
      expect(doc[:logs].size).to eq(1)
      expect(doc[:timeline].size).to eq(1)
    end

    it "strips request/response bodies when capture_level is :standard" do
      doc = buffer.to_document(capture_level: :standard)

      # Request: no body, no headers, but params are included
      expect(doc[:request][:body]).to be_nil
      expect(doc[:request][:headers]).to be_nil
      expect(doc[:request][:params]).to eq({ name: "Alice" })

      # Response: no body, no headers
      expect(doc[:response][:body]).to be_nil
      expect(doc[:response][:headers]).to be_nil
      expect(doc[:response][:status]).to eq(201)

      # SQL: normalized_sql present, raw_sql stripped
      expect(doc[:sql].first[:raw_sql]).to be_nil
      expect(doc[:sql].first[:normalized_sql]).to eq("INSERT INTO users")

      # HTTP captures: bodies stripped
      expect(doc[:http].first[:request_body]).to be_nil
      expect(doc[:http].first[:response_body]).to be_nil
      expect(doc[:http].first[:method]).to eq("POST")

      # Email: bodies stripped
      expect(doc[:email].first[:body_html]).to be_nil
      expect(doc[:email].first[:body_text]).to be_nil
      expect(doc[:email].first[:subject]).to eq("Hi")
    end

    it "strips everything when capture_level is :minimal" do
      doc = buffer.to_document(capture_level: :minimal)

      # Identity is always present
      expect(doc[:id]).to eq(buffer.id)
      expect(doc[:event_type]).to eq(:http_request)

      # Request section — only identity fields, no body/headers/params
      expect(doc[:request][:method]).to eq("POST")
      expect(doc[:request][:path]).to eq("/api/users")
      expect(doc[:request][:body]).to be_nil
      expect(doc[:request][:headers]).to be_nil
      expect(doc[:request][:params]).to be_nil

      # Domain captures stripped entirely
      expect(doc[:sql]).to be_nil
      expect(doc[:http]).to be_nil
      expect(doc[:email]).to be_nil
      expect(doc[:logs]).to be_nil
    end

    it "respects domain overrides (e.g., email_capture: :full even when base is :standard)" do
      doc = buffer.to_document(capture_level: :standard, domain_overrides: { email_capture: :full })

      # Email should be full (bodies included)
      expect(doc[:email].first[:body_html]).to eq("<p>hi</p>")
      expect(doc[:email].first[:body_text]).to eq("hi")

      # SQL should still be standard (raw_sql stripped)
      expect(doc[:sql].first[:raw_sql]).to be_nil
      expect(doc[:sql].first[:normalized_sql]).to eq("INSERT INTO users")

      # HTTP should still be standard (bodies stripped)
      expect(doc[:http].first[:request_body]).to be_nil
    end

    it "respects domain overrides to promote a domain in :minimal base" do
      doc = buffer.to_document(capture_level: :minimal, domain_overrides: { sql_capture: :standard })

      # SQL should be present at standard level
      expect(doc[:sql]).not_to be_nil
      expect(doc[:sql].first[:normalized_sql]).to eq("INSERT INTO users")
      expect(doc[:sql].first[:raw_sql]).to be_nil # standard strips raw_sql

      # Other domains remain stripped
      expect(doc[:http]).to be_nil
      expect(doc[:email]).to be_nil
    end

    it "respects :none domain overrides even when base capture is full" do
      doc = buffer.to_document(capture_level: :full, domain_overrides: { sql_capture: :none, http_capture: :none })

      expect(doc[:sql]).to be_nil
      expect(doc[:http]).to be_nil
      expect(doc[:email]).not_to be_nil
    end

    it "respects request_capture override for request and response bodies" do
      doc = buffer.to_document(capture_level: :minimal, domain_overrides: { request_capture: :full })

      expect(doc[:request][:body]).to eq('{"name": "Alice"}')
      expect(doc[:request][:headers]).to eq({ "Content-Type" => "application/json" })
      expect(doc[:response][:body]).to eq('{"id": 1}')
      expect(doc[:response][:headers]).to eq({ "X-Request-Id" => "abc" })
    end

    it "includes job fields when job_class is set" do
      buffer.job_class = "WelcomeEmailJob"
      buffer.job_id = "job-789"
      buffer.job_queue = "default"
      buffer.event_type = :job_perform

      doc = buffer.to_document(capture_level: :full)

      expect(doc[:job][:class]).to eq("WelcomeEmailJob")
      expect(doc[:job][:id]).to eq("job-789")
      expect(doc[:job][:queue]).to eq("default")
    end

    it "marks audit_truncated in document when audits were capped" do
      capped = described_class.new(max_audit_events: 1)
      capped.id = "test"
      capped.started_at = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      capped.event_type = :http_request

      2.times { |i| capped.record_audit(action: "update", record_type: "User", record_id: i) }

      doc = capped.to_document(capture_level: :full)
      expect(doc[:audit_truncated]).to eq(true)
    end

    it "marks buffer_exceeded in document when byte_size is over max" do
      tiny = described_class.new(max_buffer_bytes: 100)
      tiny.id = "test"
      tiny.started_at = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      tiny.event_type = :http_request
      tiny.request_body = "x" * 500

      doc = tiny.to_document(capture_level: :full)
      expect(doc[:buffer_exceeded]).to eq(true)
    end
  end
end
