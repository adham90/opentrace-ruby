# frozen_string_literal: true

require "spec_helper"
require "json"

RSpec.describe "Flat SDK format" do
  before do
    configure_opentrace!(flush_interval: 0.1, batch_size: 50)
  end

  def captured_payloads
    payloads = []
    WebMock.after_request do |req, _resp|
      next unless req.uri.path == "/api/logs"
      raw = decompress_body(req.body)
      batch = JSON.parse(raw)
      payloads.concat(batch.is_a?(Array) ? batch : [batch])
    end
    yield
    sleep 0.5
    OpenTrace.shutdown(timeout: 2)
    WebMock.after_request { |_, _| } # clear callback
    payloads
  end

  describe "standalone log" do
    it "sends flat format with ts, level, service, env, message" do
      entries = captured_payloads do
        OpenTrace.log("INFO", "test message", { user_id: 42 })
      end

      entry = entries.find { |e| e["message"] == "test message" }
      expect(entry).not_to be_nil

      # Required flat fields
      expect(entry["ts"]).to match(/\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}/)
      expect(entry["level"]).to eq("info")
      expect(entry["service"]).to eq("test-service")
      expect(entry["env"]).to eq("test")
      expect(entry["message"]).to eq("test message")
      expect(entry["event_type"]).to eq("log")

      # No old format fields
      expect(entry).not_to have_key("timestamp")
      expect(entry).not_to have_key("environment")
      expect(entry).not_to have_key("event")
      expect(entry).not_to have_key("id")

      # Metadata in body.context
      ctx = entry.dig("body", "context")
      expect(ctx).to include("user_id" => 42)
      expect(ctx).to include("hostname")
      expect(ctx).to include("pid")
    end

    it "sends level as lowercase" do
      entries = captured_payloads do
        OpenTrace.log("ERROR", "error test", {})
        OpenTrace.log("WARN", "warn test", {})
        OpenTrace.log("DEBUG", "debug test", {})
      end

      entries.each do |e|
        expect(e["level"]).to eq(e["level"].downcase), "level should be lowercase, got: #{e["level"]}"
      end
    end

    it "includes trace context when available" do
      entries = captured_payloads do
        Fiber[:opentrace_trace_id] = "trace-abc"
        Fiber[:opentrace_span_id] = "span-123"
        Fiber[:opentrace_request_id] = "req-456"
        OpenTrace.log("INFO", "traced log", {})
      end

      entry = entries.find { |e| e["message"] == "traced log" }
      expect(entry["trace_id"]).to eq("trace-abc")
      expect(entry["span_id"]).to eq("span-123")
      expect(entry["request_id"]).to eq("req-456")
    end
  end

  describe "error log" do
    it "sends errors in flat format" do
      entries = captured_payloads do
        begin
          raise RuntimeError, "something broke"
        rescue => e
          OpenTrace.error(e, { context: "test" })
        end
      end

      entry = entries.find { |e| e["level"] == "error" }
      expect(entry).not_to be_nil
      expect(entry["ts"]).to be_a(String)
      expect(entry["service"]).to eq("test-service")
      expect(entry["message"]).to eq("something broke")
      expect(entry["event_type"]).to eq("error")
      expect(entry.dig("body", "context", "exception_class")).to eq("RuntimeError")
    end
  end

  describe "client_enqueue_raw" do
    it "converts buffer document to flat format" do
      entries = captured_payloads do
        doc = {
          id: "test-id",
          event_type: :http_request,
          started_at: Process.clock_gettime(Process::CLOCK_MONOTONIC),
          request: { method: "GET", path: "/users", headers: { "host" => "localhost" } },
          response: { status: 200 },
          controller: "UsersController",
          action: "index",
          trace_id: "trace-999",
          request_id: "req-888",
          sql: [{ name: "User Load", duration_ms: 1.5, table: "users" }],
          logs: [{ level: "INFO", message: "Processing by UsersController#index" }],
          timeline: [{ type: "sql", name: "User Load", offset_ms: 5.0, duration_ms: 1.5 }]
        }
        OpenTrace.client_enqueue_raw(doc)
      end

      entry = entries.find { |e| e["event_type"] == "http.request" }
      expect(entry).not_to be_nil

      # Flat request fields
      expect(entry["ts"]).to be_a(String)
      expect(entry["level"]).to eq("info")
      expect(entry["method"]).to eq("GET")
      expect(entry["path"]).to eq("/users")
      expect(entry["status"]).to eq(200)
      expect(entry["duration_ms"]).to be_a(Integer)
      expect(entry["controller"]).to eq("UsersController")
      expect(entry["trace_id"]).to eq("trace-999")
      expect(entry["request_id"]).to eq("req-888")

      # Body contains captures
      body = entry["body"]
      expect(body["sql"]).to be_an(Array)
      expect(body["sql"].first["name"]).to eq("User Load")
      expect(body["logs"]).to be_an(Array)
      expect(body["timeline"]).to be_an(Array)
      expect(body["request_headers"]).to eq({ "host" => "localhost" })
    end

    it "sets level to error for 5xx status" do
      entries = captured_payloads do
        OpenTrace.client_enqueue_raw({
          request: { method: "GET", path: "/fail" },
          response: { status: 500 },
          started_at: Process.clock_gettime(Process::CLOCK_MONOTONIC)
        })
      end

      entry = entries.find { |e| e["path"] == "/fail" }
      expect(entry["level"]).to eq("error")
    end

    it "sets level to warn for 4xx status" do
      entries = captured_payloads do
        OpenTrace.client_enqueue_raw({
          request: { method: "GET", path: "/missing" },
          response: { status: 404 },
          started_at: Process.clock_gettime(Process::CLOCK_MONOTONIC)
        })
      end

      entry = entries.find { |e| e["path"] == "/missing" }
      expect(entry["level"]).to eq("warn")
    end

    it "never raises to the host app" do
      expect {
        OpenTrace.client_enqueue_raw(nil)
        OpenTrace.client_enqueue_raw("not a hash")
        OpenTrace.client_enqueue_raw({})
      }.not_to raise_error
    end
  end

  describe "batch format" do
    it "sends entries as a JSON array" do
      raw_bodies = []
      WebMock.after_request do |req, _resp|
        next unless req.uri.path == "/api/logs"
        raw_bodies << decompress_body(req.body)
      end

      configure_opentrace!(flush_interval: 0.1)
      OpenTrace.log("INFO", "batch test 1", {})
      OpenTrace.log("INFO", "batch test 2", {})
      sleep 0.5
      OpenTrace.shutdown(timeout: 2)

      expect(raw_bodies).not_to be_empty
      parsed = JSON.parse(raw_bodies.first)
      expect(parsed).to be_an(Array)
      WebMock.after_request { |_, _| }
    end
  end

  describe "endpoint" do
    it "posts to /api/logs" do
      configure_opentrace!(flush_interval: 0.1)
      OpenTrace.log("INFO", "endpoint test", {})
      sleep 0.5
      OpenTrace.shutdown(timeout: 2)

      expect(WebMock).to have_requested(:post, "https://opentrace.test/api/logs").at_least_once
    end
  end
end
