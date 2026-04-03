# frozen_string_literal: true

require_relative "request_collector"
require_relative "trace_context"
require_relative "instrumentation_context"

module OpenTrace
  class Middleware
    # All Fiber-local keys managed by this middleware.
    # Centralised so cleanup never misses one.
    FIBER_KEYS = %i[
      opentrace_collector
      opentrace_cached_context
      opentrace_sql_count
      opentrace_sql_total_ms
      opentrace_trace_id
      opentrace_span_id
      opentrace_parent_span_id
      opentrace_transaction_name
      opentrace_breadcrumbs
      opentrace_session_id
      opentrace_pending_explains
      opentrace_buffer
    ].freeze

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

      # ── Deep capture: set up InstrumentationContext ──
      buffer = setup_buffer(env, cfg)

      # ── Call the downstream app ──
      start_time = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      had_error = false

      status, headers, body = @app.call(env)

      # ── Capture response data into the buffer ──
      capture_response(buffer, status, headers, body) if buffer

      [status, headers, body]
    rescue StandardError => e
      had_error = true
      raise
    ensure
      # Calculate duration
      duration_ms = if start_time
                      ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - start_time) * 1000).round(2)
                    end

      # Memory snapshot after request (opt-in)
      collector = Fiber[:opentrace_collector]
      if collector && OpenTrace.config.memory_tracking && collector.memory_before
        collector.memory_after = current_rss_mb
      end

      # ── Deep capture: teardown and enqueue ──
      begin
        if Fiber[:opentrace_buffer]
          doc = InstrumentationContext.teardown(
            status: status,
            duration_ms: duration_ms,
            error: had_error
          )
          OpenTrace.client_enqueue_raw(doc) if doc
        end
      rescue StandardError
        # Never affect the host app
      end

      cleanup_fiber_locals
      OpenTrace.current_request_id = nil
    end

    private

    def cleanup_fiber_locals
      FIBER_KEYS.each { |key| Fiber[key] = nil }
    end

    # Set up the InstrumentationContext buffer and populate request fields.
    # Wrapped in rescue so deep capture failures never affect the host app.
    def setup_buffer(env, cfg)
      buffer = InstrumentationContext.setup(env: env)

      buffer.request_method = env["REQUEST_METHOD"]
      buffer.request_path   = env["PATH_INFO"]
      buffer.ip_address     = env["HTTP_X_FORWARDED_FOR"]&.split(",")&.first&.strip || env["REMOTE_ADDR"]
      buffer.user_agent     = env["HTTP_USER_AGENT"]
      buffer.referer        = env["HTTP_REFERER"]
      buffer.content_type   = env["CONTENT_TYPE"]

      # Capture request headers (all HTTP_* env vars, skip cookies)
      buffer.request_headers = env
        .select { |k, _| k.start_with?("HTTP_") && k != "HTTP_COOKIE" }
        .transform_keys { |k| k.sub("HTTP_", "").downcase.tr("_", "-") }

      # Capture request body (only if under size limit)
      capture_request_body(buffer, env, cfg)

      buffer.request_size = env["CONTENT_LENGTH"]&.to_i

      buffer
    rescue StandardError
      # Never affect the host app — return whatever buffer we have (or nil)
      Fiber[:opentrace_buffer]
    end

    # Read the request body from rack.input if it fits under the configured
    # max_request_body_bytes limit.
    def capture_request_body(buffer, env, cfg)
      content_length = env["CONTENT_LENGTH"]&.to_i
      return unless content_length && content_length > 0
      return unless content_length < cfg.max_request_body_bytes

      input = env["rack.input"]
      return unless input

      body = input.read
      buffer.request_body = body if body && !body.empty?
      input.rewind
    rescue StandardError
      # Never affect the host app
    end

    # Capture response status, headers, and body into the buffer.
    # For non-streaming responses, the body content is saved.
    # For streaming responses, only Content-Length is tracked.
    def capture_response(buffer, status, headers, body)
      buffer.response_status  = status
      buffer.response_headers = headers

      streaming = headers && (
        headers["Transfer-Encoding"] == "chunked" ||
        (headers.respond_to?(:key?) && !body.respond_to?(:to_ary))
      )

      if streaming
        # Streaming: only track size from Content-Length header
        buffer.response_size = headers["Content-Length"]&.to_i
      else
        # Non-streaming: collect body parts
        parts = body.respond_to?(:to_ary) ? body.to_ary : []
        collected = parts.join
        buffer.response_body = collected unless collected.empty?
        buffer.response_size = collected.bytesize
      end
    rescue StandardError
      # Never affect the host app
    end

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
