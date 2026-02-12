# frozen_string_literal: true

require "spec_helper"

RSpec.describe "Request Summary Payload" do
  before { configure_opentrace! }

  describe "OpenTrace.log with request_summary" do
    it "includes request_summary in the payload when provided" do
      summary = {
        controller: "UsersController",
        action: "index",
        method: "GET",
        path: "/users",
        status: 200,
        duration_ms: 42.5,
        sql_count: 3,
        sql_total_ms: 12.1
      }

      OpenTrace.log("INFO", "GET /users 200 42.5ms", { request_id: "req-1" }, request_summary: summary)
      sleep 0.3 # allow flush

      expect(WebMock).to have_requested(:post, "https://opentrace.test/api/logs").with { |req|
        body = parse_log_body(req)
        body["request_summary"] &&
          body["request_summary"]["controller"] == "UsersController" &&
          body["request_summary"]["sql_count"] == 3 &&
          body["metadata"]["request_id"] == "req-1" &&
          !body["metadata"].key?("controller") # controller should NOT be in metadata
      }
    end

    it "omits request_summary when not provided" do
      OpenTrace.log("INFO", "simple log", { key: "value" })
      sleep 0.3

      expect(WebMock).to have_requested(:post, "https://opentrace.test/api/logs").with { |req|
        body = parse_log_body(req)
        !body.key?("request_summary") && body["metadata"]["key"] == "value"
      }
    end

    it "preserves request_summary through payload truncation" do
      summary = {
        controller: "BigController",
        action: "show",
        sql_count: 50,
        timeline: [{ t: :sql, n: "Load", ms: 1.0, at: 0.0 }] * 100
      }

      # Large metadata to trigger truncation
      large_meta = { big_field: "x" * 30_000 }

      OpenTrace.log("INFO", "test", large_meta, request_summary: summary)
      sleep 0.3

      expect(WebMock).to have_requested(:post, "https://opentrace.test/api/logs").with { |req|
        body = parse_log_body(req)
        # After truncation, request_summary should still be present but timeline removed
        rs = body["request_summary"]
        rs && rs["controller"] == "BigController" && rs["sql_count"] == 50
      }
    end
  end
end
