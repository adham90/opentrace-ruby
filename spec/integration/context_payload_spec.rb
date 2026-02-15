# frozen_string_literal: true

RSpec.describe "Context/metadata payload integration" do
  before do
    stub_request(:post, "https://opentrace.test/api/logs")
      .to_return(status: 201, body: '{"count":1}')
  end

  describe "context proc in OpenTrace.log" do
    it "includes context fields in metadata" do
      configure_opentrace!(context: -> { { user_id: 42, tenant: "acme" } })

      OpenTrace.log("INFO", "user action")

      OpenTrace.shutdown(timeout: 5)

      expect(
        a_request(:post, "https://opentrace.test/api/logs")
          .with { |req|
            body = parse_log_body(req)
            body["metadata"]["user_id"] == 42 &&
              body["metadata"]["tenant"] == "acme"
          }
      ).to have_been_made.once
    end
  end

  describe "context proc in request log (forward_request_log path)" do
    it "resolves context even when Fiber[:opentrace_cached_context] is nil" do
      configure_opentrace!(context: -> { { user_id: 77, org: "widgets" } })

      # Simulate the bug-fix path: no OpenTrace.log() during request,
      # so Fiber[:opentrace_cached_context] is nil. forward_request_log
      # must call resolve_context_raw itself.
      Fiber[:opentrace_cached_context] = nil

      ctx = OpenTrace.send(:resolve_context_raw)
      ctx = ctx.is_a?(Hash) ? ctx : {}

      OpenTrace.client_enqueue_raw([
        :request,
        Time.now - 0.05, Time.now,
        "UsersController", "show", "GET", "/users/1", 200,
        nil, nil, nil,
        "req-ctx-bug", nil, nil, nil,
        ctx, nil, nil
      ].freeze)

      OpenTrace.shutdown(timeout: 5)

      expect(
        a_request(:post, "https://opentrace.test/api/logs")
          .with { |req|
            body = parse_log_body(req)
            body["metadata"]["user_id"] == 77 &&
              body["metadata"]["org"] == "widgets" &&
              body["request_id"] == "req-ctx-bug"
          }
      ).to have_been_made.once
    end
  end

  describe "context merged with caller metadata" do
    it "merges both context and caller-provided metadata" do
      configure_opentrace!(context: -> { { user_id: 42 } })

      OpenTrace.log("WARN", "merged test", { extra_key: "extra_val", custom: true })

      OpenTrace.shutdown(timeout: 5)

      expect(
        a_request(:post, "https://opentrace.test/api/logs")
          .with { |req|
            body = parse_log_body(req)
            meta = body["metadata"]
            meta["user_id"] == 42 &&
              meta["extra_key"] == "extra_val" &&
              meta["custom"] == true
          }
      ).to have_been_made.once
    end

    it "caller metadata overrides context on key collision" do
      configure_opentrace!(context: -> { { user_id: 1, source: "ctx" } })

      OpenTrace.log("INFO", "override test", { user_id: 99, source: "caller" })

      OpenTrace.shutdown(timeout: 5)

      expect(
        a_request(:post, "https://opentrace.test/api/logs")
          .with { |req|
            body = parse_log_body(req)
            meta = body["metadata"]
            # Caller metadata wins on collision
            meta["user_id"] == 99 &&
              meta["source"] == "caller"
          }
      ).to have_been_made.once
    end
  end

  describe "context with request_summary" do
    it "includes both request_summary fields AND metadata from context" do
      configure_opentrace!(context: -> { { user_id: 55 } })

      # Build a minimal collector double
      collector = OpenTrace::RequestCollector.new(max_timeline: 0)
      collector.record_sql(name: "User Load", duration_ms: 5.2, fingerprint: "abc")
      collector.record_sql(name: "Post Load", duration_ms: 3.1, fingerprint: "def")

      ctx = OpenTrace.send(:resolve_context_raw)
      ctx = ctx.is_a?(Hash) ? ctx : {}

      OpenTrace.client_enqueue_raw([
        :request,
        Time.now - 0.1, Time.now,
        "PostsController", "index", "GET", "/posts", 200,
        nil, nil, nil,
        "req-summary-1", nil, nil, nil,
        ctx, collector, nil
      ].freeze)

      OpenTrace.shutdown(timeout: 5)

      expect(
        a_request(:post, "https://opentrace.test/api/logs")
          .with { |req|
            body = parse_log_body(req)
            body["metadata"]["user_id"] == 55 &&
              body["request_summary"].is_a?(Hash) &&
              body["request_summary"]["controller"] == "PostsController" &&
              body["request_summary"]["sql_count"] == 2
          }
      ).to have_been_made.once
    end
  end

  describe "nil context proc" do
    it "payload still works with static context (hostname, pid)" do
      configure_opentrace! # no context: option

      OpenTrace.log("INFO", "no context proc")

      OpenTrace.shutdown(timeout: 5)

      expect(
        a_request(:post, "https://opentrace.test/api/logs")
          .with { |req|
            body = parse_log_body(req)
            meta = body["metadata"]
            body["message"] == "no context proc" &&
              meta.is_a?(Hash) &&
              meta.key?("hostname") &&
              meta.key?("pid")
          }
      ).to have_been_made.once
    end
  end

  describe "full middleware → request log flow" do
    it "Fiber-locals set by middleware are available to context resolution" do
      configure_opentrace!(context: -> { { user_id: 123, role: "admin" } })

      # Simulate what Middleware#call does: set Fiber-locals
      Fiber[:opentrace_request_id] = "req-middleware-1"
      Fiber[:opentrace_sql_count] = 0
      Fiber[:opentrace_sql_total_ms] = 0.0

      # Simulate controller action — context gets cached
      cached = OpenTrace.send(:resolve_context_raw)
      cached = cached.is_a?(Hash) ? cached : {}
      Fiber[:opentrace_cached_context] = cached

      # Simulate forward_request_log enqueuing the request
      OpenTrace.client_enqueue_raw([
        :request,
        Time.now - 0.032, Time.now,
        "DashboardController", "show", "GET", "/dashboard", 200,
        nil, nil, nil,
        "req-middleware-1", nil, nil, nil,
        cached, nil, { sql_query_count: 5, sql_total_ms: 12.3 }
      ].freeze)

      OpenTrace.shutdown(timeout: 5)

      expect(
        a_request(:post, "https://opentrace.test/api/logs")
          .with { |req|
            body = parse_log_body(req)
            meta = body["metadata"]
            meta["user_id"] == 123 &&
              meta["role"] == "admin" &&
              body["request_id"] == "req-middleware-1" &&
              meta["sql_query_count"] == 5 &&
              body["message"].include?("GET /dashboard 200")
          }
      ).to have_been_made.once
    end
  end
end
