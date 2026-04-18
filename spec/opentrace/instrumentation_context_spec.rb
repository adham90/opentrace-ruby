# frozen_string_literal: true

require "spec_helper"
require "opentrace/instrumentation_context"

RSpec.describe OpenTrace::InstrumentationContext do
  before(:each) do
    described_class.reset!
    Fiber[described_class::FIBER_KEY] = nil
    Fiber[:opentrace_buffer_allocation_bytes] = nil
  end

  after(:each) do
    # Safety: ensure Fiber local is cleaned up even if a test fails mid-way
    Fiber[described_class::FIBER_KEY] = nil
    Fiber[:opentrace_buffer_allocation_bytes] = nil
    described_class.reset!
  end

  describe ".setup" do
    it "creates a buffer with event_type :http_request when env is provided" do
      buffer = described_class.setup(env: { "PATH_INFO" => "/test" })

      expect(buffer).to be_a(OpenTrace::RequestBuffer)
      expect(buffer.event_type).to eq(:http_request)

      described_class.teardown
    end

    it "creates a buffer with event_type :job_perform when job is provided" do
      buffer = described_class.setup(job: { class: "MyJob", id: "123" })

      expect(buffer).to be_a(OpenTrace::RequestBuffer)
      expect(buffer.event_type).to eq(:job_perform)

      described_class.teardown
    end

    it "sets the buffer on the current Fiber" do
      buffer = described_class.setup(env: { "PATH_INFO" => "/" })

      expect(Fiber[described_class::FIBER_KEY]).to equal(buffer)

      described_class.teardown
    end

    it "assigns an id and started_at to the buffer" do
      buffer = described_class.setup(env: { "PATH_INFO" => "/" })

      expect(buffer.id).to be_a(String)
      expect(buffer.id.length).to eq(26) # ULID
      expect(buffer.started_at).to be_a(Float)
      expect(buffer.started_at).to be > 0

      described_class.teardown
    end

    it "preserves existing Fiber locals" do
      Fiber[:opentrace_request_id] = "req-abc"
      Fiber[:opentrace_trace_id] = "trace-xyz"

      described_class.setup(env: { "PATH_INFO" => "/" })

      expect(Fiber[:opentrace_request_id]).to eq("req-abc")
      expect(Fiber[:opentrace_trace_id]).to eq("trace-xyz")

      described_class.teardown
    end

    it "returns the buffer" do
      result = described_class.setup(env: { "PATH_INFO" => "/" })

      expect(result).to be_a(OpenTrace::RequestBuffer)
      expect(result).to equal(described_class.current_buffer)

      described_class.teardown
    end

    it "does not activate a buffer when the global memory guard denies allocation" do
      guard = described_class.memory_guard
      guard.allocate(guard.max_total_bytes)

      result = described_class.setup(env: { "PATH_INFO" => "/" })

      expect(result).to be_nil
      expect(described_class.current_buffer).to be_nil
    ensure
      guard&.release(guard.max_total_bytes)
    end
  end

  describe ".active?" do
    it "returns true after setup" do
      described_class.setup(env: { "PATH_INFO" => "/" })

      expect(described_class.active?).to be true

      described_class.teardown
    end

    it "returns false after teardown" do
      described_class.setup(env: { "PATH_INFO" => "/" })
      described_class.teardown

      expect(described_class.active?).to be false
    end

    it "returns false when no setup has been called" do
      expect(described_class.active?).to be false
    end
  end

  describe ".current_buffer" do
    it "returns the buffer during setup" do
      buffer = described_class.setup(env: { "PATH_INFO" => "/" })

      expect(described_class.current_buffer).to equal(buffer)

      described_class.teardown
    end

    it "returns nil when no buffer is active" do
      expect(described_class.current_buffer).to be_nil
    end
  end

  describe ".teardown" do
    it "returns a document Hash" do
      described_class.setup(env: { "PATH_INFO" => "/" })
      doc = described_class.teardown

      expect(doc).to be_a(Hash)
      expect(doc[:id]).to be_a(String)
      expect(doc[:event_type]).to eq(:http_request)
    end

    it "checks buffer back into pool" do
      pool = described_class.buffer_pool
      initial_stats = pool.stats

      described_class.setup(env: { "PATH_INFO" => "/" })
      expect(pool.stats[:checked_out]).to eq(initial_stats[:checked_out] + 1)

      described_class.teardown
      expect(pool.stats[:checked_out]).to eq(initial_stats[:checked_out])
    end

    it "releases global memory guard allocation after teardown" do
      guard = described_class.memory_guard

      described_class.setup(env: { "PATH_INFO" => "/" })
      expect(guard.current_bytes).to be > 0

      described_class.teardown

      expect(guard.current_bytes).to eq(0)
    end

    it "clears Fiber local" do
      described_class.setup(env: { "PATH_INFO" => "/" })
      expect(Fiber[described_class::FIBER_KEY]).not_to be_nil

      described_class.teardown
      expect(Fiber[described_class::FIBER_KEY]).to be_nil
      expect(Fiber[:opentrace_buffer_allocation_bytes]).to be_nil
    end

    it "returns nil when no buffer is active" do
      result = described_class.teardown
      expect(result).to be_nil
    end

    it "includes captured data in the document" do
      buffer = described_class.setup(env: { "PATH_INFO" => "/" })
      buffer.request_method = "GET"
      buffer.request_path = "/users"
      buffer.record_sql(raw_sql: "SELECT 1", duration_ms: 1.5)

      doc = described_class.teardown

      expect(doc[:request]).to include(method: "GET", path: "/users")
      expect(doc[:sql]).to be_a(Array)
      expect(doc[:sql].length).to eq(1)
    end

    context "with CaptureRules configured" do
      it "drops the document when rules resolve to :none" do
        rules = OpenTrace::CaptureRules.new do |r|
          r.on_path("/drop") { :none }
        end
        described_class.capture_rules = rules

        buffer = described_class.setup(env: { "PATH_INFO" => "/drop" })
        buffer.request_method = "GET"
        buffer.request_path = "/drop"

        doc = described_class.teardown(status: 200, duration_ms: 1)

        expect(doc).to be_nil
        expect(described_class.current_buffer).to be_nil
      end

      it "resolves capture level from rules" do
        rules = OpenTrace::CaptureRules.new do |r|
          r.on_path("/api/**") { :full }
          r.on_path("/health") { :minimal }
        end
        described_class.capture_rules = rules

        # Test /api path -> :full
        buffer = described_class.setup(env: { "PATH_INFO" => "/api/users" })
        buffer.request_path = "/api/users"
        buffer.request_method = "GET"
        buffer.request_body = "full body data"
        buffer.record_sql(raw_sql: "SELECT * FROM users", duration_ms: 2.0)

        doc = described_class.teardown

        # :full level includes raw_sql (bodies are NOT stripped)
        sql_entry = doc[:sql]&.first
        expect(sql_entry).not_to be_nil
        expect(sql_entry[:raw_sql]).to eq("SELECT * FROM users")

        # Test /health path -> :minimal (no sql section)
        buffer = described_class.setup(env: { "PATH_INFO" => "/health" })
        buffer.request_path = "/health"
        buffer.request_method = "GET"
        buffer.record_sql(raw_sql: "SELECT 1", duration_ms: 0.5)

        doc = described_class.teardown

        # :minimal level strips domain captures entirely
        expect(doc[:sql]).to be_nil
      end

      it "upgrades capture level on error via on_error rule" do
        rules = OpenTrace::CaptureRules.new do |r|
          r.on_path("/health") { :minimal }
          r.on_error { :full }
        end
        described_class.capture_rules = rules

        buffer = described_class.setup(env: { "PATH_INFO" => "/health" })
        buffer.request_path = "/health"
        buffer.request_method = "GET"
        buffer.record_sql(raw_sql: "SELECT 1", duration_ms: 0.5)

        # Error should upgrade from :minimal to :full
        doc = described_class.teardown(error: true)

        expect(doc[:sql]).not_to be_nil
        expect(doc[:sql].first[:raw_sql]).to eq("SELECT 1")
      end

      it "upgrades capture level on slow request via on_slow rule" do
        rules = OpenTrace::CaptureRules.new do |r|
          r.on_slow(threshold: 100) { :full }
        end
        described_class.capture_rules = rules

        buffer = described_class.setup(env: { "PATH_INFO" => "/slow" })
        buffer.request_path = "/slow"
        buffer.request_method = "GET"
        buffer.request_body = "payload data"

        doc = described_class.teardown(duration_ms: 500)

        # :full capture includes request body
        expect(doc[:request][:body]).to eq("payload data")
      end

      after(:each) do
        described_class.capture_rules = nil
      end
    end

    context "with MemoryGuard under pressure" do
      it "applies memory guard effective level" do
        guard = described_class.memory_guard

        # Put system under pressure so it downgrades
        guard.update_pressure(0.95)

        buffer = described_class.setup(env: { "PATH_INFO" => "/" })
        buffer.request_method = "GET"
        buffer.request_path = "/test"
        buffer.request_body = "should be stripped"
        buffer.record_sql(raw_sql: "SELECT 1", duration_ms: 1.0)

        doc = described_class.teardown

        # Under pressure, :standard downgrades to :minimal.
        # :minimal strips domain captures.
        expect(doc[:sql]).to be_nil
      end

      it "refuses new buffers when memory is already at the global limit" do
        guard = described_class.memory_guard
        max = guard.max_total_bytes

        guard.allocate(max)

        expect(described_class.setup(env: { "PATH_INFO" => "/" })).to be_nil
        expect(described_class.teardown).to be_nil
      ensure
        guard&.release(max)
      end
    end

    context "with OpenTrace config" do
      def configure_capture!(overrides = {})
        OpenTrace.configure do |c|
          c.endpoint = "https://opentrace.test"
          c.api_key = "test-key"
          c.service = "test-app"
          overrides.each do |key, value|
            next if key == :capture_rules
            c.public_send("#{key}=", value)
          end
          c.capture_rules(&overrides[:capture_rules]) if overrides[:capture_rules]
        end
      end

      it "uses configured capture_depth" do
        configure_capture!(capture_depth: :full)

        buffer = described_class.setup(env: { "PATH_INFO" => "/full" })
        buffer.request_method = "POST"
        buffer.request_path = "/full"
        buffer.request_body = "full request body"

        doc = described_class.teardown(status: 200, duration_ms: 1)

        expect(doc[:request][:body]).to eq("full request body")
      end

      it "installs capture_rules from OpenTrace.configure" do
        configure_capture!(
          capture_rules: proc { |r| r.on_path("/private") { :minimal } }
        )

        buffer = described_class.setup(env: { "PATH_INFO" => "/private" })
        buffer.request_method = "GET"
        buffer.request_path = "/private"
        buffer.record_sql(raw_sql: "SELECT * FROM users", duration_ms: 1.0)

        doc = described_class.teardown(status: 200, duration_ms: 1)

        expect(doc[:sql]).to be_nil
      end

      it "uses configured domain overrides" do
        configure_capture!(capture_depth: :minimal, sql_capture: :standard, request_capture: :full)

        buffer = described_class.setup(env: { "PATH_INFO" => "/override" })
        buffer.request_method = "POST"
        buffer.request_path = "/override"
        buffer.request_body = "request body"
        buffer.record_sql(raw_sql: "SELECT * FROM users WHERE id = 1", normalized_sql: "SELECT * FROM users WHERE id = ?", duration_ms: 1.0)

        doc = described_class.teardown(status: 200, duration_ms: 1)

        expect(doc[:request][:body]).to eq("request body")
        expect(doc[:sql]).not_to be_nil
        expect(doc[:sql].first[:normalized_sql]).to eq("SELECT * FROM users WHERE id = ?")
        expect(doc[:sql].first[:raw_sql]).to be_nil
      end

      it "uses configured buffer and audit limits" do
        configure_capture!(capture_depth: :full, max_buffer_bytes: 100, audit_max_events_per_request: 1)

        buffer = described_class.setup(env: { "PATH_INFO" => "/limits" })
        buffer.request_method = "POST"
        buffer.request_path = "/limits"
        buffer.request_body = "x" * 500
        2.times { |i| buffer.record_audit(action: "update", record_type: "User", record_id: i) }

        doc = described_class.teardown(status: 200, duration_ms: 1)

        expect(doc[:buffer_exceeded]).to be true
        expect(doc[:audit].size).to eq(1)
        expect(doc[:audit_truncated]).to be true
      end

      it "uses configured total memory limit" do
        configure_capture!(max_total_buffer_bytes: 1234)

        expect(described_class.memory_guard.max_total_bytes).to eq(1234)
      end
    end
  end

  describe "multiple setup/teardown cycles" do
    it "reuses buffers from pool" do
      pool = described_class.buffer_pool

      buffer1 = described_class.setup(env: { "PATH_INFO" => "/" })
      buffer1_id = buffer1.object_id
      described_class.teardown

      buffer2 = described_class.setup(env: { "PATH_INFO" => "/" })
      buffer2_id = buffer2.object_id
      described_class.teardown

      # Pool should reuse the same buffer object
      expect(buffer2_id).to eq(buffer1_id)
    end

    it "resets buffer state between cycles" do
      buffer = described_class.setup(env: { "PATH_INFO" => "/" })
      buffer.request_method = "GET"
      buffer.request_path = "/first"
      buffer.record_sql(raw_sql: "SELECT 1", duration_ms: 1.0)
      described_class.teardown

      buffer = described_class.setup(env: { "PATH_INFO" => "/" })
      expect(buffer.request_method).to be_nil
      expect(buffer.request_path).to be_nil
      expect(buffer.sql_captures).to be_empty
      described_class.teardown
    end

    it "handles interleaved request and job contexts" do
      # Simulate: request setup -> teardown -> job setup -> teardown
      req_buffer = described_class.setup(env: { "PATH_INFO" => "/api" })
      expect(req_buffer.event_type).to eq(:http_request)
      doc1 = described_class.teardown
      expect(doc1[:event_type]).to eq(:http_request)

      job_buffer = described_class.setup(job: { class: "ProcessJob" })
      expect(job_buffer.event_type).to eq(:job_perform)
      doc2 = described_class.teardown
      expect(doc2[:event_type]).to eq(:job_perform)
    end
  end

  describe ".buffer_pool" do
    it "returns a BufferPool instance" do
      expect(described_class.buffer_pool).to be_a(OpenTrace::BufferPool)
    end

    it "returns the same instance on repeated calls" do
      pool1 = described_class.buffer_pool
      pool2 = described_class.buffer_pool
      expect(pool1).to equal(pool2)
    end
  end

  describe ".memory_guard" do
    it "returns a MemoryGuard instance" do
      expect(described_class.memory_guard).to be_a(OpenTrace::MemoryGuard)
    end

    it "returns the same instance on repeated calls" do
      guard1 = described_class.memory_guard
      guard2 = described_class.memory_guard
      expect(guard1).to equal(guard2)
    end
  end

  describe ".reset!" do
    it "creates new singleton instances after reset" do
      pool_before = described_class.buffer_pool
      guard_before = described_class.memory_guard

      described_class.reset!

      pool_after = described_class.buffer_pool
      guard_after = described_class.memory_guard

      expect(pool_after).not_to equal(pool_before)
      expect(guard_after).not_to equal(guard_before)
    end
  end
end
