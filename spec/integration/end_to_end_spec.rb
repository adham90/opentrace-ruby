# frozen_string_literal: true

require "stringio"

RSpec.describe "End-to-end integration" do
  before do
    stub_request(:post, "https://opentrace.test/api/logs")
      .to_return(status: 201, body: '{"count":1}')
  end

  describe "full flow: configure -> log -> HTTP" do
    it "sends a well-formed payload from configure to server" do
      OpenTrace.configure do |c|
        c.endpoint    = "https://opentrace.test"
        c.api_key     = "integration-key"
        c.service     = "integration-svc"
        c.environment = "test"
      end

      OpenTrace.log("ERROR", "Integration test error", {
        trace_id: "trace-int-001",
        user_id: 99,
        request_id: "req-int-001"
      })

      OpenTrace.shutdown(timeout: 5)

      expect(
        a_request(:post, "https://opentrace.test/api/logs")
          .with { |req|
            body = parse_log_body(req)
            body["level"] == "ERROR" &&
              body["message"] == "Integration test error" &&
              body["service"] == "integration-svc" &&
              body["environment"] == "test" &&
              body["trace_id"] == "trace-int-001" &&
              body["metadata"]["user_id"] == 99 &&
              body["request_id"] == "req-int-001" &&
              !body["metadata"].key?("trace_id") &&
              body["timestamp"].match?(/\A\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}/)
          }
      ).to have_been_made.once

      expect(
        a_request(:post, "https://opentrace.test/api/logs")
          .with(headers: {
            "Authorization" => "Bearer integration-key",
            "Content-Type" => "application/json"
          })
      ).to have_been_made.once
    end
  end

  describe "full flow: Logger wrapper -> HTTP" do
    it "forwards logger output to both the wrapped logger and OpenTrace" do
      OpenTrace.configure do |c|
        c.endpoint    = "https://opentrace.test"
        c.api_key     = "logger-key"
        c.service     = "logger-svc"
        c.environment = "test"
      end

      io = StringIO.new
      wrapped = ::Logger.new(io)
      logger = OpenTrace::Logger.new(wrapped)

      logger.warn("Logger integration test")

      OpenTrace.shutdown(timeout: 5)

      # Verify the wrapped logger received the message
      expect(io.string).to include("Logger integration test")

      # Verify OpenTrace received the forwarded message
      expect(
        a_request(:post, "https://opentrace.test/api/logs")
          .with { |req|
            body = parse_log_body(req)
            body["level"] == "WARN" &&
              body["message"] == "Logger integration test" &&
              body["service"] == "logger-svc"
          }
      ).to have_been_made
    end
  end

  describe "multiple rapid logs" do
    it "delivers all logs to the server" do
      received = []
      stub_request(:post, "https://opentrace.test/api/logs")
        .to_return { |req|
          batch = JSON.parse(req.body)
          received.concat(batch)
          { status: 201, body: "{\"count\":#{batch.size}}" }
        }

      configure_opentrace!

      count = 20
      count.times { |i| OpenTrace.log("INFO", "rapid-#{i}") }

      OpenTrace.shutdown(timeout: 5)

      expect(received.size).to eq(count)
    end
  end

  describe "concurrent logging from multiple threads" do
    it "delivers logs without errors" do
      received = []
      stub_request(:post, "https://opentrace.test/api/logs")
        .to_return { |req|
          batch = JSON.parse(req.body)
          received.concat(batch)
          { status: 201, body: "{\"count\":#{batch.size}}" }
        }

      configure_opentrace!

      threads = 5.times.map do |t|
        Thread.new do
          10.times { |i| OpenTrace.log("INFO", "thread-#{t}-msg-#{i}") }
        end
      end
      threads.each(&:join)

      OpenTrace.shutdown(timeout: 5)

      expect(received.size).to eq(50)
    end
  end

  describe "disable mid-stream" do
    it "stops sending after disable!" do
      configure_opentrace!

      OpenTrace.log("INFO", "before disable")
      sleep 0.3
      OpenTrace.disable!

      WebMock.reset!
      stub_request(:post, "https://opentrace.test/api/logs")
        .to_return(status: 201, body: '{"count":1}')

      OpenTrace.log("INFO", "after disable")
      sleep 0.3

      expect(
        a_request(:post, "https://opentrace.test/api/logs")
          .with { |req| parse_log_body(req)["message"] == "after disable" }
      ).not_to have_been_made
    end
  end

  describe "server unavailable" do
    it "silently drops logs when the server returns errors" do
      stub_request(:post, "https://opentrace.test/api/logs")
        .to_return(status: 503, body: "Service Unavailable")

      configure_opentrace!

      expect {
        5.times { OpenTrace.log("ERROR", "server down") }
        OpenTrace.shutdown(timeout: 5)
      }.not_to raise_error
    end

    it "silently drops logs when the connection is refused" do
      stub_request(:post, "https://opentrace.test/api/logs")
        .to_raise(Errno::ECONNREFUSED)

      configure_opentrace!

      expect {
        5.times { OpenTrace.log("ERROR", "connection refused") }
        OpenTrace.shutdown(timeout: 5)
      }.not_to raise_error
    end
  end

  describe "context proc in payload" do
    it "includes context data in metadata when context proc is configured" do
      OpenTrace.configure do |c|
        c.endpoint    = "https://opentrace.test"
        c.api_key     = "ctx-key"
        c.service     = "ctx-svc"
        c.environment = "test"
        c.context     = -> { { user_id: 42, tenant: "acme" } }
      end

      OpenTrace.log("INFO", "with context", { extra_key: "val" })

      OpenTrace.shutdown(timeout: 5)

      expect(
        a_request(:post, "https://opentrace.test/api/logs")
          .with { |req|
            body = parse_log_body(req)
            body["metadata"]["user_id"] == 42 &&
              body["metadata"]["tenant"] == "acme" &&
              body["metadata"]["extra_key"] == "val"
          }
      ).to have_been_made.once
    end

    it "includes context data in request log payload" do
      OpenTrace.configure do |c|
        c.endpoint    = "https://opentrace.test"
        c.api_key     = "ctx-key"
        c.service     = "ctx-svc"
        c.environment = "test"
        c.context     = -> { { user_id: 99 } }
        c.flush_interval = 0.2
        c.compression = false
      end

      # Simulate what forward_request_log does after the fix:
      # resolve context if not cached
      ctx = OpenTrace.send(:resolve_context_raw)
      ctx = ctx.is_a?(Hash) ? ctx : {}

      OpenTrace.client_enqueue_raw([
        :request,
        Time.now - 0.05, Time.now,
        "OrdersController", "create", "POST", "/orders", 201,
        nil, nil, nil,
        "req-ctx-1", nil, nil, nil,
        ctx, nil, nil
      ].freeze)

      OpenTrace.shutdown(timeout: 5)

      expect(
        a_request(:post, "https://opentrace.test/api/logs")
          .with { |req|
            body = parse_log_body(req)
            body["metadata"]["user_id"] == 99 &&
              body["request_id"] == "req-ctx-1"
          }
      ).to have_been_made.once
    end
  end

  describe "reconfiguration" do
    it "switches to new endpoint after reconfigure" do
      configure_opentrace!
      OpenTrace.log("INFO", "to old endpoint")
      OpenTrace.shutdown(timeout: 3)

      new_stub = stub_request(:post, "https://new-server.test/api/logs")
        .to_return(status: 201, body: '{"count":1}')

      OpenTrace.configure do |c|
        c.endpoint    = "https://new-server.test"
        c.api_key     = "new-key"
        c.service     = "new-svc"
        c.environment = "test"
      end

      OpenTrace.log("INFO", "to new endpoint")
      OpenTrace.shutdown(timeout: 3)

      expect(new_stub).to have_been_requested.once
    end
  end
end
