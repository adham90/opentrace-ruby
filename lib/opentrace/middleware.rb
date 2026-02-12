# frozen_string_literal: true

require_relative "request_collector"

module OpenTrace
  class Middleware
    def initialize(app)
      @app = app
    end

    def call(env)
      request_id = env["action_dispatch.request_id"] || env["HTTP_X_REQUEST_ID"]
      OpenTrace.current_request_id = request_id
      Fiber[:opentrace_sql_count] = 0
      Fiber[:opentrace_sql_total_ms] = 0.0

      # Create RequestCollector for accumulate-and-summarize pattern
      if OpenTrace.enabled? && OpenTrace.config.request_summary
        collector = OpenTrace::RequestCollector.new(
          max_timeline: OpenTrace.config.timeline_max_events
        )
        Fiber[:opentrace_collector] = collector

        # Memory snapshot before request (opt-in)
        if OpenTrace.config.memory_tracking
          collector.memory_before = current_rss_mb
        end
      end

      @app.call(env)
    ensure
      # Memory snapshot after request (opt-in)
      collector = Fiber[:opentrace_collector]
      if collector && OpenTrace.config.memory_tracking && collector.memory_before
        collector.memory_after = current_rss_mb
      end

      Fiber[:opentrace_collector] = nil
      Fiber[:opentrace_cached_context] = nil
      Fiber[:opentrace_sql_count] = nil
      Fiber[:opentrace_sql_total_ms] = nil
      OpenTrace.current_request_id = nil
    end

    private

    def current_rss_mb
      if RUBY_PLATFORM.include?("linux")
        # Linux: read from /proc — no fork, ~10μs
        File.read("/proc/self/statm").split[1].to_i * 4096.0 / 1024 / 1024
      else
        # macOS/other: use GC.stat as lightweight approximation
        # Avoids forking a `ps` subprocess which costs 2-5ms
        gc = GC.stat
        gc[:heap_live_slots].to_f * 40 / 1024 / 1024 # rough estimate: ~40 bytes per slot
      end
    rescue StandardError
      nil
    end
  end
end
