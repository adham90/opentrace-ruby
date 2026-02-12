# frozen_string_literal: true

RSpec.describe "Trace context propagation" do
  before do
    configure_opentrace!
    stub_request(:any, /opentrace\.test/)
      .to_return(status: 200, body: '{"count":0}')
    stub_request(:post, "https://opentrace.test/api/logs")
      .to_return(status: 201, body: '{"count":1}')
  end

  describe "payload includes span fields" do
    it "includes span_id when set in Fiber locals" do
      Fiber[:opentrace_span_id] = "00f067aa0ba902b7"
      Fiber[:opentrace_trace_id] = "4bf92f3577b34da6a3ce929d0e0e4736"

      OpenTrace.log("INFO", "traced message")
      sleep 0.5

      expect(
        a_request(:post, "https://opentrace.test/api/logs")
          .with { |req|
            body = parse_log_body(req)
            body["span_id"] == "00f067aa0ba902b7" &&
              body["trace_id"] == "4bf92f3577b34da6a3ce929d0e0e4736"
          }
      ).to have_been_made
    end

    it "includes parent_span_id when set in Fiber locals" do
      Fiber[:opentrace_span_id] = "00f067aa0ba902b7"
      Fiber[:opentrace_parent_span_id] = "e5f678901234abcd"
      Fiber[:opentrace_trace_id] = "4bf92f3577b34da6a3ce929d0e0e4736"

      OpenTrace.log("INFO", "child span message")
      sleep 0.5

      expect(
        a_request(:post, "https://opentrace.test/api/logs")
          .with { |req|
            body = parse_log_body(req)
            body["parent_span_id"] == "e5f678901234abcd"
          }
      ).to have_been_made
    end

    it "omits span fields when not set" do
      OpenTrace.log("INFO", "no trace context")
      sleep 0.5

      expect(
        a_request(:post, "https://opentrace.test/api/logs")
          .with { |req|
            body = parse_log_body(req)
            !body.key?("span_id") && !body.key?("parent_span_id")
          }
      ).to have_been_made
    end

    it "uses Fiber-local trace_id when metadata lacks trace_id" do
      Fiber[:opentrace_trace_id] = "abcdef1234567890abcdef1234567890"

      OpenTrace.log("INFO", "fiber trace")
      sleep 0.5

      expect(
        a_request(:post, "https://opentrace.test/api/logs")
          .with { |req|
            body = parse_log_body(req)
            body["trace_id"] == "abcdef1234567890abcdef1234567890"
          }
      ).to have_been_made
    end

    it "prefers metadata trace_id over Fiber-local" do
      Fiber[:opentrace_trace_id] = "aaaa0000000000000000000000000000"

      OpenTrace.log("INFO", "explicit trace", { trace_id: "explicit-trace-id" })
      sleep 0.5

      expect(
        a_request(:post, "https://opentrace.test/api/logs")
          .with { |req|
            body = parse_log_body(req)
            body["trace_id"] == "explicit-trace-id"
          }
      ).to have_been_made
    end
  end

  describe "event method includes span fields" do
    it "includes trace context in events" do
      Fiber[:opentrace_trace_id] = "4bf92f3577b34da6a3ce929d0e0e4736"
      Fiber[:opentrace_span_id] = "00f067aa0ba902b7"

      OpenTrace.event("payment.completed", "Payment processed")
      sleep 0.5

      expect(
        a_request(:post, "https://opentrace.test/api/logs")
          .with { |req|
            body = parse_log_body(req)
            body["trace_id"] == "4bf92f3577b34da6a3ce929d0e0e4736" &&
              body["span_id"] == "00f067aa0ba902b7"
          }
      ).to have_been_made
    end
  end
end
