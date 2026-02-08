# frozen_string_literal: true

RSpec.describe OpenTrace do
  describe ".configure" do
    it "yields a config object" do
      OpenTrace.configure do |c|
        expect(c).to be_a(OpenTrace::Config)
      end
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
  end

  describe ".disable! / .enable!" do
    before { configure_opentrace! }

    it "disables and re-enables" do
      expect(OpenTrace.enabled?).to be true

      OpenTrace.disable!
      expect(OpenTrace.enabled?).to be false

      OpenTrace.enable!
      expect(OpenTrace.enabled?).to be true
    end
  end

  describe ".log" do
    before do
      configure_opentrace!
      stub_request(:post, "https://opentrace.test/api/logs")
        .to_return(status: 201, body: '{"count":1}')
    end

    it "sends a log payload to the server" do
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

    it "extracts trace_id to top level" do
      OpenTrace.log("INFO", "traced", { trace_id: "abc-123" })
      sleep 0.5

      expect(
        a_request(:post, "https://opentrace.test/api/logs")
          .with { |req|
            body = JSON.parse(req.body)
            body["trace_id"] == "abc-123"
          }
      ).to have_been_made
    end

    it "does nothing when disabled" do
      OpenTrace.disable!
      OpenTrace.log("INFO", "should not send")
      sleep 0.3

      expect(a_request(:post, "https://opentrace.test/api/logs")).not_to have_been_made
    end

    it "never raises on any error" do
      OpenTrace.reset!
      expect { OpenTrace.log("ERROR", "test") }.not_to raise_error
    end

    it "handles non-hash metadata gracefully" do
      expect { OpenTrace.log("INFO", "test", "not a hash") }.not_to raise_error
    end
  end

  describe ".shutdown" do
    it "can be called without error even when unconfigured" do
      expect { OpenTrace.shutdown }.not_to raise_error
    end
  end
end
