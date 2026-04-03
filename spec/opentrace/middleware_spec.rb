# frozen_string_literal: true

require "stringio"

RSpec.describe OpenTrace::Middleware do
  let(:inner_app) { ->(env) { [200, { "Content-Type" => "text/plain" }, ["OK"]] } }
  subject(:middleware) { described_class.new(inner_app) }

  after do
    OpenTrace.current_request_id = nil
    Fiber[:opentrace_buffer] = nil
  end

  describe "#call" do
    before { configure_opentrace! }

    it "sets request_id from action_dispatch.request_id" do
      captured_id = nil
      app = described_class.new(->(env) {
        captured_id = OpenTrace.current_request_id
        [200, {}, ["OK"]]
      })

      app.call("action_dispatch.request_id" => "req-abc-123")

      expect(captured_id).to eq("req-abc-123")
    end

    it "falls back to X-Request-Id header" do
      captured_id = nil
      app = described_class.new(->(env) {
        captured_id = OpenTrace.current_request_id
        [200, {}, ["OK"]]
      })

      app.call("HTTP_X_REQUEST_ID" => "x-req-456")

      expect(captured_id).to eq("x-req-456")
    end

    it "prefers action_dispatch.request_id over header" do
      captured_id = nil
      app = described_class.new(->(env) {
        captured_id = OpenTrace.current_request_id
        [200, {}, ["OK"]]
      })

      app.call(
        "action_dispatch.request_id" => "dispatch-id",
        "HTTP_X_REQUEST_ID" => "header-id"
      )

      expect(captured_id).to eq("dispatch-id")
    end

    it "cleans up request_id after the request" do
      OpenTrace.current_request_id = "stale"

      middleware.call("action_dispatch.request_id" => "during-request")

      expect(OpenTrace.current_request_id).to be_nil
    end

    it "cleans up request_id even when the app raises" do
      error_app = described_class.new(->(env) { raise "boom" })

      expect { error_app.call("action_dispatch.request_id" => "req-err") }.to raise_error("boom")
      expect(OpenTrace.current_request_id).to be_nil
    end

    it "passes through the app response" do
      status, headers, body = middleware.call({})

      expect(status).to eq(200)
      expect(body).to eq(["OK"])
    end

    it "sets nil when no request_id is present" do
      OpenTrace.current_request_id = "stale"

      middleware.call({})

      expect(OpenTrace.current_request_id).to be_nil
    end
  end

  describe "integration with OpenTrace.log" do
    before do
      configure_opentrace!
      stub_request(:post, "https://opentrace.test/api/logs")
        .to_return(status: 201, body: '{"count":1}')
    end

    it "logs are captured in the request buffer (not sent individually)" do
      captured_logs = nil
      app = described_class.new(->(env) {
        OpenTrace.log("INFO", "inside request")
        buf = Fiber[:opentrace_buffer]
        captured_logs = buf&.logs&.dup
        [200, {}, ["OK"]]
      })

      app.call("action_dispatch.request_id" => "req-in-log")

      expect(captured_logs).not_to be_nil
      expect(captured_logs.length).to eq(1)
      expect(captured_logs.first[:message]).to eq("inside request")
    end

    it "metadata from log calls is captured in the buffer" do
      captured_logs = nil
      app = described_class.new(->(env) {
        OpenTrace.log("INFO", "custom id", { request_id: "custom-override" })
        buf = Fiber[:opentrace_buffer]
        captured_logs = buf&.logs&.dup
        [200, {}, ["OK"]]
      })

      app.call("action_dispatch.request_id" => "middleware-id")

      expect(captured_logs).not_to be_nil
      expect(captured_logs.first[:metadata][:request_id]).to eq("custom-override")
    end
  end

  describe "deep capture integration" do
    before do
      configure_opentrace!
      OpenTrace::InstrumentationContext.reset!
    end

    after do
      OpenTrace::InstrumentationContext.reset!
    end

    # Helper: capture buffer field snapshots during the request,
    # since teardown resets the buffer object after the middleware returns.
    def capture_buffer_snapshot(*fields, &setup_env)
      snapshot = {}
      app = described_class.new(->(env) {
        buf = Fiber[:opentrace_buffer]
        if buf
          fields.each { |f| snapshot[f] = buf.send(f) }
          snapshot[:_class] = buf.class
          snapshot[:_event_type] = buf.event_type
        end
        [200, { "Content-Type" => "text/plain" }, ["OK"]]
      })
      env = setup_env.call
      app.call(env)
      snapshot
    end

    describe "buffer setup" do
      it "sets up InstrumentationContext buffer during request" do
        snapshot = capture_buffer_snapshot(:request_method) do
          { "REQUEST_METHOD" => "GET", "PATH_INFO" => "/test" }
        end

        expect(snapshot[:_class]).to eq(OpenTrace::RequestBuffer)
      end

      it "sets event_type to :http_request" do
        snapshot = capture_buffer_snapshot(:event_type) do
          { "REQUEST_METHOD" => "GET", "PATH_INFO" => "/test" }
        end

        expect(snapshot[:_event_type]).to eq(:http_request)
      end

      it "captures request method and path" do
        snapshot = capture_buffer_snapshot(:request_method, :request_path) do
          { "REQUEST_METHOD" => "POST", "PATH_INFO" => "/api/users" }
        end

        expect(snapshot[:request_method]).to eq("POST")
        expect(snapshot[:request_path]).to eq("/api/users")
      end

      it "captures IP address from X-Forwarded-For" do
        snapshot = capture_buffer_snapshot(:ip_address) do
          {
            "REQUEST_METHOD" => "GET",
            "PATH_INFO" => "/",
            "HTTP_X_FORWARDED_FOR" => "203.0.113.50, 70.41.3.18",
            "REMOTE_ADDR" => "127.0.0.1"
          }
        end

        expect(snapshot[:ip_address]).to eq("203.0.113.50")
      end

      it "falls back to REMOTE_ADDR when X-Forwarded-For is absent" do
        snapshot = capture_buffer_snapshot(:ip_address) do
          {
            "REQUEST_METHOD" => "GET",
            "PATH_INFO" => "/",
            "REMOTE_ADDR" => "192.168.1.100"
          }
        end

        expect(snapshot[:ip_address]).to eq("192.168.1.100")
      end

      it "captures user agent and referer" do
        snapshot = capture_buffer_snapshot(:user_agent, :referer) do
          {
            "REQUEST_METHOD" => "GET",
            "PATH_INFO" => "/",
            "HTTP_USER_AGENT" => "Mozilla/5.0",
            "HTTP_REFERER" => "https://example.com"
          }
        end

        expect(snapshot[:user_agent]).to eq("Mozilla/5.0")
        expect(snapshot[:referer]).to eq("https://example.com")
      end

      it "captures content type" do
        snapshot = capture_buffer_snapshot(:content_type) do
          {
            "REQUEST_METHOD" => "POST",
            "PATH_INFO" => "/data",
            "CONTENT_TYPE" => "application/json"
          }
        end

        expect(snapshot[:content_type]).to eq("application/json")
      end

      it "captures request headers excluding cookies" do
        snapshot = capture_buffer_snapshot(:request_headers) do
          {
            "REQUEST_METHOD" => "GET",
            "PATH_INFO" => "/",
            "HTTP_ACCEPT" => "text/html",
            "HTTP_AUTHORIZATION" => "Bearer tok123",
            "HTTP_COOKIE" => "session=abc"
          }
        end

        headers = snapshot[:request_headers]
        expect(headers).to be_a(Hash)
        expect(headers["accept"]).to eq("text/html")
        expect(headers["authorization"]).to eq("Bearer tok123")
        expect(headers).not_to have_key("cookie")
      end

      it "captures request size" do
        snapshot = capture_buffer_snapshot(:request_size) do
          {
            "REQUEST_METHOD" => "POST",
            "PATH_INFO" => "/data",
            "CONTENT_LENGTH" => "42"
          }
        end

        expect(snapshot[:request_size]).to eq(42)
      end
    end

    describe "request body capture" do
      it "captures request body when under size limit" do
        body_content = '{"name":"test"}'
        captured_body = nil
        app = described_class.new(->(env) {
          buf = Fiber[:opentrace_buffer]
          captured_body = buf&.request_body
          [200, {}, ["OK"]]
        })

        app.call(
          "REQUEST_METHOD" => "POST",
          "PATH_INFO" => "/api/users",
          "CONTENT_TYPE" => "application/json",
          "CONTENT_LENGTH" => body_content.bytesize.to_s,
          "rack.input" => StringIO.new(body_content)
        )

        expect(captured_body).to eq(body_content)
      end

      it "rewinds rack.input after reading" do
        body_content = '{"key":"value"}'
        rack_input = StringIO.new(body_content)
        app = described_class.new(->(env) {
          # The downstream app should still be able to read the body
          read_body = env["rack.input"].read
          [200, {}, [read_body]]
        })

        status, _, body = app.call(
          "REQUEST_METHOD" => "POST",
          "PATH_INFO" => "/",
          "CONTENT_LENGTH" => body_content.bytesize.to_s,
          "rack.input" => rack_input
        )

        expect(body).to eq([body_content])
      end

      it "skips request body when over size limit" do
        # Default max_request_body_bytes is 262_144 (256KB)
        large_body = "x" * 300_000
        captured_body = nil
        app = described_class.new(->(env) {
          buf = Fiber[:opentrace_buffer]
          captured_body = buf&.request_body
          [200, {}, ["OK"]]
        })

        app.call(
          "REQUEST_METHOD" => "POST",
          "PATH_INFO" => "/upload",
          "CONTENT_TYPE" => "application/octet-stream",
          "CONTENT_LENGTH" => large_body.bytesize.to_s,
          "rack.input" => StringIO.new(large_body)
        )

        expect(captured_body).to be_nil
      end

      it "skips request body when CONTENT_LENGTH is missing" do
        captured_body = nil
        app = described_class.new(->(env) {
          buf = Fiber[:opentrace_buffer]
          captured_body = buf&.request_body
          [200, {}, ["OK"]]
        })

        app.call(
          "REQUEST_METHOD" => "GET",
          "PATH_INFO" => "/"
        )

        expect(captured_body).to be_nil
      end
    end

    describe "response capture" do
      it "captures response status" do
        enqueued = []
        allow(OpenTrace).to receive(:client_enqueue_raw) { |doc| enqueued << doc }

        app = described_class.new(->(env) {
          [201, { "Content-Type" => "application/json" }, ['{"id":1}']]
        })

        app.call("REQUEST_METHOD" => "POST", "PATH_INFO" => "/api/users")

        doc = enqueued.last
        expect(doc).not_to be_nil
        expect(doc[:response][:status]).to eq(201)
      end

      it "captures response headers" do
        enqueued = []
        allow(OpenTrace).to receive(:client_enqueue_raw) { |doc| enqueued << doc }

        app = described_class.new(->(env) {
          [200, { "Content-Type" => "text/html", "X-Custom" => "val" }, ["<h1>Hi</h1>"]]
        })

        app.call("REQUEST_METHOD" => "GET", "PATH_INFO" => "/")

        doc = enqueued.last
        expect(doc).not_to be_nil
        expect(doc[:response][:status]).to eq(200)
      end

      it "captures response body for non-streaming responses" do
        enqueued = []
        allow(OpenTrace).to receive(:client_enqueue_raw) { |doc| enqueued << doc }

        app = described_class.new(->(env) {
          [200, { "Content-Type" => "text/plain" }, ["Hello", " ", "World"]]
        })

        app.call("REQUEST_METHOD" => "GET", "PATH_INFO" => "/hello")

        doc = enqueued.last
        expect(doc).not_to be_nil
        expect(doc[:response][:size]).to eq("Hello World".bytesize)
      end

      it "skips body capture for streaming (chunked) responses" do
        enqueued = []
        allow(OpenTrace).to receive(:client_enqueue_raw) { |doc| enqueued << doc }

        # Simulate a streaming response -- Transfer-Encoding: chunked, body not responding to to_ary
        streaming_body = Object.new
        def streaming_body.each; yield "chunk1"; yield "chunk2"; end

        app = described_class.new(->(env) {
          [200, { "Transfer-Encoding" => "chunked", "Content-Length" => "500" }, streaming_body]
        })

        app.call("REQUEST_METHOD" => "GET", "PATH_INFO" => "/stream")

        doc = enqueued.last
        expect(doc).not_to be_nil
        expect(doc[:response][:status]).to eq(200)
        expect(doc[:response][:size]).to eq(500)
      end

      it "skips body capture for non-to_ary responses even without chunked header" do
        enqueued = []
        allow(OpenTrace).to receive(:client_enqueue_raw) { |doc| enqueued << doc }

        # Body that doesn't respond to to_ary (e.g., a file body proxy)
        non_array_body = Object.new
        def non_array_body.each; yield "data"; end

        app = described_class.new(->(env) {
          [200, { "Content-Length" => "4" }, non_array_body]
        })

        app.call("REQUEST_METHOD" => "GET", "PATH_INFO" => "/file")

        doc = enqueued.last
        expect(doc).not_to be_nil
        expect(doc[:response][:status]).to eq(200)
        expect(doc[:response][:size]).to eq(4)
      end

      it "returns the original response to the caller" do
        original_body = ["original"]
        app = described_class.new(->(env) {
          [200, { "Content-Type" => "text/plain" }, original_body]
        })

        status, headers, body = app.call("REQUEST_METHOD" => "GET", "PATH_INFO" => "/")

        expect(status).to eq(200)
        expect(body).to equal(original_body)
      end
    end

    describe "document enqueuing" do
      it "enqueues document after request completes" do
        enqueued = []
        allow(OpenTrace).to receive(:client_enqueue_raw) { |doc| enqueued << doc }

        app = described_class.new(->(env) {
          [200, { "Content-Type" => "text/plain" }, ["OK"]]
        })

        app.call(
          "REQUEST_METHOD" => "GET",
          "PATH_INFO" => "/test",
          "REMOTE_ADDR" => "10.0.0.1"
        )

        expect(enqueued.length).to eq(1)
        doc = enqueued.first
        expect(doc[:event_type]).to eq(:http_request)
        expect(doc[:id]).to be_a(String)
        expect(doc[:request][:method]).to eq("GET")
        expect(doc[:request][:path]).to eq("/test")
      end

      it "enqueues document even when the app raises" do
        enqueued = []
        allow(OpenTrace).to receive(:client_enqueue_raw) { |doc| enqueued << doc }

        error_app = described_class.new(->(env) { raise "kaboom" })

        expect {
          error_app.call("REQUEST_METHOD" => "GET", "PATH_INFO" => "/fail")
        }.to raise_error("kaboom")

        expect(enqueued.length).to eq(1)
        doc = enqueued.first
        expect(doc[:request][:path]).to eq("/fail")
      end

      it "does not enqueue when OpenTrace is disabled" do
        OpenTrace.disable!

        enqueued = []
        allow(OpenTrace).to receive(:client_enqueue_raw) { |doc| enqueued << doc }

        middleware.call("REQUEST_METHOD" => "GET", "PATH_INFO" => "/")

        expect(enqueued).to be_empty
      end
    end

    describe "buffer cleanup" do
      it "cleans up buffer Fiber local after the request" do
        middleware.call("REQUEST_METHOD" => "GET", "PATH_INFO" => "/")

        expect(Fiber[:opentrace_buffer]).to be_nil
      end

      it "cleans up buffer Fiber local even when the app raises" do
        error_app = described_class.new(->(env) { raise "boom" })

        expect { error_app.call("REQUEST_METHOD" => "GET", "PATH_INFO" => "/err") }.to raise_error("boom")

        expect(Fiber[:opentrace_buffer]).to be_nil
      end

      it "includes opentrace_buffer in FIBER_KEYS" do
        expect(described_class::FIBER_KEYS).to include(:opentrace_buffer)
      end
    end

    describe "backward compatibility" do
      it "still sets up Fiber[:opentrace_collector] when collector features are enabled" do
        configure_opentrace!(
          request_summary: true,
          view_tracking: true
        )

        captured_collector = nil
        app = described_class.new(->(env) {
          captured_collector = Fiber[:opentrace_collector]
          [200, {}, ["OK"]]
        })

        app.call("REQUEST_METHOD" => "GET", "PATH_INFO" => "/")

        expect(captured_collector).to be_a(OpenTrace::RequestCollector)
      end

      it "still sets Fiber[:opentrace_sql_count] and Fiber[:opentrace_sql_total_ms]" do
        captured_sql_count = nil
        captured_sql_total = nil
        app = described_class.new(->(env) {
          captured_sql_count = Fiber[:opentrace_sql_count]
          captured_sql_total = Fiber[:opentrace_sql_total_ms]
          [200, {}, ["OK"]]
        })

        app.call("REQUEST_METHOD" => "GET", "PATH_INFO" => "/")

        expect(captured_sql_count).to eq(0)
        expect(captured_sql_total).to eq(0.0)
      end
    end
  end
end
