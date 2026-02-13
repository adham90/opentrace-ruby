# frozen_string_literal: true

require_relative "request_collector"
require_relative "trace_context"

module OpenTrace
  class Middleware
    def initialize(app)
      @app = app
    end

    def call(env)
      # When OpenTrace is disabled, pass through with zero overhead
      return @app.call(env) unless OpenTrace.enabled?

      # Sampling: skip ALL Fiber-local setup for unsampled requests.
      # Subscribers check Fiber-locals and return instantly when nil.
      unless OpenTrace.sampler.sample?(env)
        OpenTrace.send(:client).stats.increment(:sampled_out)
        return @app.call(env)
      end

      request_id = env["action_dispatch.request_id"] || env["HTTP_X_REQUEST_ID"]
      OpenTrace.current_request_id = request_id
      Fiber[:opentrace_sql_count] = 0
      Fiber[:opentrace_sql_total_ms] = 0.0

      # Extract or generate trace context
      if OpenTrace.config.trace_propagation
        trace_id, parent_span_id = extract_trace_context(env)
        span_id = TraceContext.generate_span_id

        Fiber[:opentrace_trace_id] = trace_id
        Fiber[:opentrace_span_id] = span_id
        Fiber[:opentrace_parent_span_id] = parent_span_id
      end

      # Session tracking (opt-in)
      if OpenTrace.config.session_tracking
        session_id = extract_session_id(env)
        Fiber[:opentrace_session_id] = session_id if session_id
      end

      # Create RequestCollector only when features that need it are enabled
      cfg = OpenTrace.config
      needs_collector = cfg.request_summary &&
        (cfg.view_tracking || cfg.cache_tracking || cfg.http_tracking ||
         cfg.timeline || cfg.memory_tracking)

      if needs_collector
        max_timeline = cfg.timeline ? cfg.timeline_max_events : 0
        collector = OpenTrace::RequestCollector.new(max_timeline: max_timeline)
        Fiber[:opentrace_collector] = collector

        if cfg.memory_tracking
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
      Fiber[:opentrace_trace_id] = nil
      Fiber[:opentrace_span_id] = nil
      Fiber[:opentrace_parent_span_id] = nil
      Fiber[:opentrace_transaction_name] = nil
      Fiber[:opentrace_breadcrumbs] = nil
      Fiber[:opentrace_session_id] = nil
      OpenTrace.current_request_id = nil
    end

    private

    # Extract trace context from incoming request headers.
    # Priority: W3C traceparent > X-Trace-ID > request_id > generate new
    def extract_trace_context(env)
      parent_span_id = nil

      # Try W3C traceparent first
      if (traceparent = env["HTTP_TRACEPARENT"])
        parsed = TraceContext.parse_traceparent(traceparent)
        if parsed
          return [parsed[:trace_id], parsed[:parent_id]]
        end
      end

      # Try OpenTrace/custom trace ID header
      if (trace_id = env["HTTP_X_TRACE_ID"])
        normalized = TraceContext.normalize_trace_id(trace_id)
        return [normalized, parent_span_id] if normalized
      end

      # Fall back to request_id (Rails convention)
      request_id = env["action_dispatch.request_id"] || env["HTTP_X_REQUEST_ID"]
      if request_id
        normalized = TraceContext.normalize_trace_id(request_id)
        return [normalized, parent_span_id] if normalized
      end

      # Generate new trace ID
      [TraceContext.generate_trace_id, nil]
    end

    def extract_session_id(env)
      # Try Rack session first
      if (session = env["rack.session"])
        return session.id.to_s if session.respond_to?(:id) && session.id
      end

      # Fall back to session cookie
      cookie_name = env.dig("rack.session.options", :key) || "_session_id"
      cookies = env["HTTP_COOKIE"]
      if cookies
        match = cookies.match(/#{Regexp.escape(cookie_name)}=([^;]+)/)
        return match[1] if match
      end

      nil
    rescue StandardError
      nil
    end

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
