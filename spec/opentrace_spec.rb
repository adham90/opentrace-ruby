# frozen_string_literal: true

RSpec.describe OpenTrace do
  describe ".configure" do
    it "yields a config object" do
      OpenTrace.configure do |c|
        expect(c).to be_a(OpenTrace::Config)
      end
    end

    it "preserves config values across calls" do
      OpenTrace.configure do |c|
        c.endpoint = "https://opentrace.test"
        c.api_key = "key-1"
        c.service = "svc"
      end

      OpenTrace.configure do |c|
        c.api_key = "key-2"
      end

      expect(OpenTrace.config.api_key).to eq("key-2")
      expect(OpenTrace.config.endpoint).to eq("https://opentrace.test")
    end

    it "resets the client when reconfigured" do
      configure_opentrace!

      stub = stub_request(:post, "https://opentrace.test/api/logs")
        .to_return(status: 201, body: '{"count":1}')

      OpenTrace.log("INFO", "before reconfig")
      sleep 0.3

      # Reconfigure with a different endpoint
      new_stub = stub_request(:post, "https://new-endpoint.test/api/logs")
        .to_return(status: 201, body: '{"count":1}')

      OpenTrace.configure do |c|
        c.endpoint = "https://new-endpoint.test"
        c.api_key = "new-key"
        c.service = "new-svc"
      end

      OpenTrace.log("INFO", "after reconfig")
      sleep 0.5

      expect(new_stub).to have_been_requested
    end
  end

  describe ".enabled?" do
    it "returns false without configuration" do
      expect(OpenTrace.enabled?).to be false
    end

    it "returns true with valid configuration" do
      configure_opentrace!
      expect(OpenTrace.enabled?).to be true
    end

    it "returns false when a required field is missing" do
      OpenTrace.configure do |c|
        c.endpoint = "https://opentrace.test"
        # missing api_key and service
      end
      expect(OpenTrace.enabled?).to be false
    end
  end

  describe ".disable! / .enable!" do
    before { configure_opentrace! }

    it "disables logging" do
      OpenTrace.disable!
      expect(OpenTrace.enabled?).to be false
    end

    it "re-enables logging" do
      OpenTrace.disable!
      OpenTrace.enable!
      expect(OpenTrace.enabled?).to be true
    end

    it "actually stops sending logs when disabled" do
      stub = stub_request(:post, "https://opentrace.test/api/logs")
        .to_return(status: 201, body: '{"count":1}')

      OpenTrace.disable!
      OpenTrace.log("INFO", "should not send")
      sleep 0.3

      expect(stub).not_to have_been_requested
    end
  end

  describe ".log" do
    before do
      configure_opentrace!
      stub_request(:post, "https://opentrace.test/api/logs")
        .to_return(status: 201, body: '{"count":1}')
    end

    it "sends a log payload with all expected fields" do
      OpenTrace.log("INFO", "test message", { request_id: "req-1" })
      sleep 0.5

      expect(
        a_request(:post, "https://opentrace.test/api/logs")
          .with { |req|
            body = JSON.parse(req.body)
            body["level"] == "INFO" &&
              body["message"] == "test message" &&
              body["service"] == "test-service" &&
              body["environment"] == "test" &&
              body["metadata"]["request_id"] == "req-1" &&
              body["timestamp"].is_a?(String)
          }
      ).to have_been_made
    end

    it "generates an ISO 8601 timestamp with microseconds" do
      OpenTrace.log("INFO", "ts test")
      sleep 0.5

      expect(
        a_request(:post, "https://opentrace.test/api/logs")
          .with { |req|
            body = JSON.parse(req.body)
            # Matches: 2026-02-08T12:34:56.123456Z
            body["timestamp"].match?(/\A\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d{6}Z\z/)
          }
      ).to have_been_made
    end

    it "upcases the level string" do
      OpenTrace.log("info", "lower case level")
      sleep 0.5

      expect(
        a_request(:post, "https://opentrace.test/api/logs")
          .with { |req| JSON.parse(req.body)["level"] == "INFO" }
      ).to have_been_made
    end

    it "converts symbol levels" do
      OpenTrace.log(:warn, "symbol level")
      sleep 0.5

      expect(
        a_request(:post, "https://opentrace.test/api/logs")
          .with { |req| JSON.parse(req.body)["level"] == "WARN" }
      ).to have_been_made
    end

    it "converts message to string" do
      OpenTrace.log("ERROR", 12345)
      sleep 0.5

      expect(
        a_request(:post, "https://opentrace.test/api/logs")
          .with { |req| JSON.parse(req.body)["message"] == "12345" }
      ).to have_been_made
    end

    it "extracts trace_id to top level" do
      OpenTrace.log("INFO", "traced", { trace_id: "abc-123", other: "val" })
      sleep 0.5

      expect(
        a_request(:post, "https://opentrace.test/api/logs")
          .with { |req|
            body = JSON.parse(req.body)
            body["trace_id"] == "abc-123" &&
              !body["metadata"].key?("trace_id") &&
              body["metadata"]["other"] == "val"
          }
      ).to have_been_made
    end

    it "sends empty metadata hash when none provided" do
      OpenTrace.log("INFO", "no meta")
      sleep 0.5

      expect(
        a_request(:post, "https://opentrace.test/api/logs")
          .with { |req| JSON.parse(req.body)["metadata"] == {} }
      ).to have_been_made
    end

    it "does nothing when disabled" do
      OpenTrace.disable!
      OpenTrace.log("INFO", "should not send")
      sleep 0.3

      # Only the safety-net stub should exist, no real request
      expect(
        a_request(:post, "https://opentrace.test/api/logs")
          .with { |req| JSON.parse(req.body)["message"] == "should not send" }
      ).not_to have_been_made
    end

    it "never raises on any error" do
      OpenTrace.reset!
      expect { OpenTrace.log("ERROR", "test") }.not_to raise_error
    end

    it "handles non-hash metadata gracefully" do
      expect { OpenTrace.log("INFO", "test", "not a hash") }.not_to raise_error
    end

    it "handles nil metadata gracefully" do
      expect { OpenTrace.log("INFO", "test", nil) }.not_to raise_error
    end

    it "includes complex nested metadata" do
      metadata = {
        exception: {
          class: "RuntimeError",
          message: "boom",
          backtrace: ["file.rb:1", "file.rb:2"]
        },
        user_id: 42
      }
      OpenTrace.log("ERROR", "exception caught", metadata)
      sleep 0.5

      expect(
        a_request(:post, "https://opentrace.test/api/logs")
          .with { |req|
            body = JSON.parse(req.body)
            body["metadata"]["exception"]["class"] == "RuntimeError" &&
              body["metadata"]["user_id"] == 42
          }
      ).to have_been_made
    end
  end

  describe "config.context" do
    before do
      configure_opentrace!
      stub_request(:post, "https://opentrace.test/api/logs")
        .to_return(status: 201, body: '{"count":1}')
    end

    it "merges hash context into metadata" do
      OpenTrace.config.context = { tenant: "acme", region: "us-east" }
      OpenTrace.log("INFO", "ctx test")
      sleep 0.5

      expect(
        a_request(:post, "https://opentrace.test/api/logs")
          .with { |req|
            meta = JSON.parse(req.body)["metadata"]
            meta["tenant"] == "acme" && meta["region"] == "us-east"
          }
      ).to have_been_made
    end

    it "evaluates proc context per call" do
      counter = 0
      OpenTrace.config.context = -> { counter += 1; { call_num: counter } }
      OpenTrace.log("INFO", "first")
      OpenTrace.log("INFO", "second")
      sleep 0.5

      expect(counter).to be >= 2
    end

    it "caller metadata overrides context" do
      OpenTrace.config.context = { user_id: 1 }
      OpenTrace.log("INFO", "override", { user_id: 99 })
      sleep 0.5

      expect(
        a_request(:post, "https://opentrace.test/api/logs")
          .with { |req| JSON.parse(req.body)["metadata"]["user_id"] == 99 }
      ).to have_been_made
    end

    it "swallows broken proc without crashing" do
      OpenTrace.config.context = -> { raise "boom" }
      expect { OpenTrace.log("INFO", "safe") }.not_to raise_error
    end

    it "works with nil context (default)" do
      OpenTrace.config.context = nil
      OpenTrace.log("INFO", "nil ctx")
      sleep 0.5

      expect(a_request(:post, "https://opentrace.test/api/logs")).to have_been_made
    end

    it "ignores proc returning non-hash" do
      OpenTrace.config.context = -> { "bad" }
      OpenTrace.log("INFO", "non-hash")
      sleep 0.5

      expect(a_request(:post, "https://opentrace.test/api/logs")).to have_been_made
    end
  end

  describe "config.min_level" do
    before do
      configure_opentrace!
      stub_request(:post, "https://opentrace.test/api/logs")
        .to_return(status: 201, body: '{"count":1}')
    end

    it "sends everything by default (min_level = :debug)" do
      OpenTrace.log("DEBUG", "debug msg")
      sleep 0.5

      expect(
        a_request(:post, "https://opentrace.test/api/logs")
          .with { |req| JSON.parse(req.body)["level"] == "DEBUG" }
      ).to have_been_made
    end

    it "filters out DEBUG and INFO when min_level is :warn" do
      OpenTrace.config.min_level = :warn

      WebMock.reset!
      stub_request(:post, "https://opentrace.test/api/logs")
        .to_return(status: 201, body: '{"count":1}')

      OpenTrace.log("DEBUG", "should not send")
      OpenTrace.log("INFO", "should not send")
      OpenTrace.log("WARN", "should send")
      sleep 0.5

      expect(
        a_request(:post, "https://opentrace.test/api/logs")
          .with { |req| JSON.parse(req.body)["level"] == "WARN" }
      ).to have_been_made

      expect(
        a_request(:post, "https://opentrace.test/api/logs")
          .with { |req| %w[DEBUG INFO].include?(JSON.parse(req.body)["level"]) }
      ).not_to have_been_made
    end

    it "filters out WARN when min_level is :error" do
      OpenTrace.config.min_level = :error

      WebMock.reset!
      stub_request(:post, "https://opentrace.test/api/logs")
        .to_return(status: 201, body: '{"count":1}')

      OpenTrace.log("WARN", "should not send")
      OpenTrace.log("ERROR", "should send")
      sleep 0.5

      expect(
        a_request(:post, "https://opentrace.test/api/logs")
          .with { |req| JSON.parse(req.body)["level"] == "ERROR" }
      ).to have_been_made

      expect(
        a_request(:post, "https://opentrace.test/api/logs")
          .with { |req| JSON.parse(req.body)["level"] == "WARN" }
      ).not_to have_been_made
    end

    it "accepts string min_level" do
      OpenTrace.config.min_level = "info"

      WebMock.reset!
      stub_request(:post, "https://opentrace.test/api/logs")
        .to_return(status: 201, body: '{"count":1}')

      OpenTrace.log("DEBUG", "filtered out")
      OpenTrace.log("INFO", "passes")
      sleep 0.5

      expect(
        a_request(:post, "https://opentrace.test/api/logs")
          .with { |req| JSON.parse(req.body)["level"] == "DEBUG" }
      ).not_to have_been_made

      expect(
        a_request(:post, "https://opentrace.test/api/logs")
          .with { |req| JSON.parse(req.body)["level"] == "INFO" }
      ).to have_been_made
    end
  end

  describe ".shutdown" do
    it "can be called without error even when unconfigured" do
      expect { OpenTrace.shutdown }.not_to raise_error
    end

    it "can be called multiple times" do
      configure_opentrace!
      expect {
        OpenTrace.shutdown(timeout: 1)
        OpenTrace.shutdown(timeout: 1)
      }.not_to raise_error
    end
  end

  describe ".reset!" do
    it "clears configuration" do
      configure_opentrace!
      expect(OpenTrace.enabled?).to be true

      OpenTrace.reset!
      expect(OpenTrace.enabled?).to be false
    end

    it "can be called safely multiple times" do
      expect {
        3.times { OpenTrace.reset! }
      }.not_to raise_error
    end
  end
end
