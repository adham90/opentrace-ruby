# frozen_string_literal: true

RSpec.describe "Performance" do
  before do
    configure_opentrace!
    stub_request(:post, "https://opentrace.test/api/logs")
      .to_return(status: 201, body: '{"count":1}')
  end

  describe "OpenTrace.log overhead" do
    it "completes 1000 log calls within 500ms" do
      start = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      1000.times { |i| OpenTrace.log("INFO", "benchmark #{i}") }
      elapsed = (Process.clock_gettime(Process::CLOCK_MONOTONIC) - start) * 1000

      expect(elapsed).to be < 500, "1000 log calls took #{elapsed.round(1)}ms (limit: 500ms)"
    end

    it "enqueue is non-blocking (under 1ms per call)" do
      # Warm up
      OpenTrace.log("INFO", "warmup")

      times = []
      100.times do
        start = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        OpenTrace.log("INFO", "timing test")
        elapsed = (Process.clock_gettime(Process::CLOCK_MONOTONIC) - start) * 1000
        times << elapsed
      end

      avg = times.sum / times.size
      p95 = times.sort[(times.size * 0.95).to_i]

      expect(avg).to be < 1.0, "Average log call took #{avg.round(3)}ms (limit: 1ms)"
      expect(p95).to be < 2.0, "P95 log call took #{p95.round(3)}ms (limit: 2ms)"
    end
  end

  describe "context proc caching" do
    it "resolves the context proc exactly once per request (cached, not per-log)" do
      call_count = 0
      configure_opentrace!(context: -> {
        call_count += 1
        { user_id: 42 }
      })

      middleware = OpenTrace::Middleware.new(->(env) {
        5.times { OpenTrace.log("INFO", "inside request") }
        [200, {}, ["OK"]]
      })

      middleware.call("action_dispatch.request_id" => "perf-test")

      # Resolved once at buffer setup and cached in Fiber[:opentrace_cached_context];
      # the 5 in-request log calls must not re-run the (expensive) proc.
      expect(call_count).to eq(1), "Context proc was called #{call_count} times (expected 1: resolved once, cached)"
    end

    it "evaluates context proc for standalone log calls" do
      call_count = 0
      configure_opentrace!(context: -> {
        call_count += 1
        { user_id: 42 }
      })

      3.times { OpenTrace.log("INFO", "outside request") }

      expect(call_count).to eq(3), "Context proc was called #{call_count} times (expected 3 outside request)"
    end

    it "does not cache outside of request context" do
      call_count = 0
      configure_opentrace!(context: -> {
        call_count += 1
        { user_id: 42 }
      })

      3.times { OpenTrace.log("INFO", "outside request") }

      expect(call_count).to eq(3), "Context proc was called #{call_count} times (expected 3 outside request)"
    end
  end

  describe "re-entrance guard" do
    it "prevents recursive logging from context proc" do
      recursive_count = 0
      configure_opentrace!(context: -> {
        recursive_count += 1
        # This would cause infinite recursion without the guard
        OpenTrace.log("INFO", "recursive log from context proc")
        { user_id: 1 }
      })

      OpenTrace.log("INFO", "trigger")

      # Should only enter once — the recursive call is blocked
      expect(recursive_count).to eq(1)
    end

    it "allows logging after re-entrance guard clears" do
      configure_opentrace!(context: -> {
        OpenTrace.log("INFO", "recursive -- should be blocked")
        { user_id: 1 }
      })

      # First call
      OpenTrace.log("INFO", "first call")
      # Guard should be cleared -- second call should work
      OpenTrace.log("INFO", "second call")

      OpenTrace.shutdown(timeout: 5)

      # Both non-recursive calls should have been enqueued
      expect(
        a_request(:post, "https://opentrace.test/api/logs")
          .with { |req|
            body = JSON.parse(decompress_body(req.body))
            body = [body] unless body.is_a?(Array)
            body.any? { |entry| entry["message"] == "first call" }
          }
      ).to have_been_made

      expect(
        a_request(:post, "https://opentrace.test/api/logs")
          .with { |req|
            body = JSON.parse(decompress_body(req.body))
            body = [body] unless body.is_a?(Array)
            body.any? { |entry| entry["message"] == "second call" }
          }
      ).to have_been_made
    end
  end

  describe "middleware overhead" do
    it "adds minimal overhead to request processing" do
      inner_app = ->(env) { [200, {}, ["OK"]] }
      middleware = OpenTrace::Middleware.new(inner_app)

      # Baseline without middleware
      baseline_times = []
      100.times do
        start = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        inner_app.call({})
        baseline_times << (Process.clock_gettime(Process::CLOCK_MONOTONIC) - start) * 1000
      end

      # With middleware
      middleware_times = []
      100.times do
        start = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        middleware.call("action_dispatch.request_id" => "perf-#{_1}")
        middleware_times << (Process.clock_gettime(Process::CLOCK_MONOTONIC) - start) * 1000
      end

      baseline_avg = baseline_times.sum / baseline_times.size
      middleware_avg = middleware_times.sum / middleware_times.size
      overhead = middleware_avg - baseline_avg

      expect(overhead).to be < 1.0,
        "Middleware overhead: #{overhead.round(3)}ms (baseline: #{baseline_avg.round(3)}ms, with middleware: #{middleware_avg.round(3)}ms)"
    end

    it "cleans up all Fiber-local state after request" do
      middleware = OpenTrace::Middleware.new(->(env) { [200, {}, ["OK"]] })

      middleware.call("action_dispatch.request_id" => "cleanup-test")

      expect(Fiber[:opentrace_request_id]).to be_nil
      expect(Fiber[:opentrace_cached_context]).to be_nil
      expect(Fiber[:opentrace_buffer]).to be_nil
    end

    it "cleans up Fiber-local state even on exception" do
      middleware = OpenTrace::Middleware.new(->(env) { raise "boom" })

      expect { middleware.call("action_dispatch.request_id" => "err-test") }.to raise_error("boom")

      expect(Fiber[:opentrace_request_id]).to be_nil
      expect(Fiber[:opentrace_cached_context]).to be_nil
    end
  end

  describe "disabled mode has zero overhead" do
    it "returns immediately when disabled" do
      configure_opentrace!(enabled: false)

      start = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      10_000.times { OpenTrace.log("INFO", "disabled") }
      elapsed = (Process.clock_gettime(Process::CLOCK_MONOTONIC) - start) * 1000

      expect(elapsed).to be < 50, "10000 disabled log calls took #{elapsed.round(1)}ms (limit: 50ms)"
    end
  end

  describe "level filtering avoids unnecessary work" do
    it "does not evaluate context proc for filtered levels" do
      context_evaluated = false
      configure_opentrace!(
        min_level: :warn,
        context: -> { context_evaluated = true; {} }
      )

      OpenTrace.log("DEBUG", "should not evaluate context")
      OpenTrace.log("INFO", "should not evaluate context")

      expect(context_evaluated).to be false
    end
  end
end
