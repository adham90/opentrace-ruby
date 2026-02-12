# frozen_string_literal: true

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
        require_relative "request_collector"
        Fiber[:opentrace_collector] = OpenTrace::RequestCollector.new(
          max_timeline: OpenTrace.config.timeline_max_events
        )
      end

      @app.call(env)
    ensure
      Fiber[:opentrace_collector] = nil
      Fiber[:opentrace_sql_count] = nil
      Fiber[:opentrace_sql_total_ms] = nil
      OpenTrace.current_request_id = nil
    end
  end
end
