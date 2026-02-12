# frozen_string_literal: true

require "net/http"

module OpenTrace
  module HttpTracker
    def request(req, body = nil, &block)
      # Guard 1: skip if disabled
      return super unless OpenTrace.enabled?

      # Guard 2: skip if this IS an OpenTrace dispatch call (prevent infinite recursion)
      return super if Fiber[:opentrace_http_tracking_disabled]

      # Inject trace context into outgoing request headers
      inject_trace_context(req) if OpenTrace.config.trace_propagation

      collector = Fiber[:opentrace_collector]
      start_time = Process.clock_gettime(Process::CLOCK_MONOTONIC)

      response = super

      duration_ms = (Process.clock_gettime(Process::CLOCK_MONOTONIC) - start_time) * 1000
      host = address
      port_str = (port == 443 || port == 80) ? "" : ":#{port}"
      scheme = use_ssl? ? "https" : "http"
      url = "#{scheme}://#{host}#{port_str}#{req.path}"

      if collector
        collector.record_http(
          method: req.method,
          url: url,
          host: host,
          status: response.code.to_i,
          duration_ms: duration_ms
        )
      end

      response
    rescue IOError, SystemCallError, OpenSSL::SSL::SSLError, Timeout::Error, Net::ProtocolError => e
      # Record the failed HTTP call, then re-raise
      duration_ms = start_time ? (Process.clock_gettime(Process::CLOCK_MONOTONIC) - start_time) * 1000 : 0

      if collector
        collector.record_http(
          method: req&.method,
          url: "#{address}#{req&.path}",
          host: address,
          status: 0,
          duration_ms: duration_ms,
          error: e.class.name
        )
      end

      raise # ALWAYS re-raise — never swallow app errors
    end

    private

    def inject_trace_context(req)
      trace_id = Fiber[:opentrace_trace_id]
      span_id = Fiber[:opentrace_span_id]
      return unless trace_id

      # Set X-Trace-ID for OpenTrace-to-OpenTrace propagation
      req["X-Trace-ID"] = trace_id

      # Set X-Request-ID for Rails convention compatibility
      request_id = Fiber[:opentrace_request_id]
      req["X-Request-ID"] = request_id if request_id

      # Set W3C traceparent for interoperability with OpenTelemetry etc.
      if span_id
        req["traceparent"] = TraceContext.build_traceparent(
          trace_id: trace_id,
          span_id: span_id
        )
      end
    rescue StandardError
      # Never let trace propagation break the HTTP call
    end
  end
end
