# frozen_string_literal: true

RSpec.describe OpenTrace::Middleware do
  let(:inner_app) { ->(env) { [200, {}, ["OK"]] } }
  subject(:middleware) { described_class.new(inner_app) }

  after { OpenTrace.current_request_id = nil }

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

    it "request_id appears in log metadata" do
      app = described_class.new(->(env) {
        OpenTrace.log("INFO", "inside request")
        [200, {}, ["OK"]]
      })

      app.call("action_dispatch.request_id" => "req-in-log")
      OpenTrace.shutdown(timeout: 5)

      expect(
        a_request(:post, "https://opentrace.test/api/logs")
          .with { |req|
            body = parse_log_body(req)
            body["request_id"] == "req-in-log"
          }
      ).to have_been_made
    end

    it "explicit request_id in metadata overrides middleware" do
      app = described_class.new(->(env) {
        OpenTrace.log("INFO", "custom id", { request_id: "custom-override" })
        [200, {}, ["OK"]]
      })

      app.call("action_dispatch.request_id" => "middleware-id")
      OpenTrace.shutdown(timeout: 5)

      expect(
        a_request(:post, "https://opentrace.test/api/logs")
          .with { |req|
            body = parse_log_body(req)
            body["request_id"] == "custom-override"
          }
      ).to have_been_made
    end
  end
end
