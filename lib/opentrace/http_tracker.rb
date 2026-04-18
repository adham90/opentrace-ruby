# frozen_string_literal: true

require "net/http"

module OpenTrace
  module HttpTracker
    # Max body size to capture (64KB) — avoids bloating memory with large payloads
    MAX_BODY_CAPTURE_BYTES = 65_536

    VENDOR_PATTERNS = {
      "stripe" => /api\.stripe\.com/i,
      "sendgrid" => /api\.sendgrid\.com/i,
      "twilio" => /api\.twilio\.com/i,
      "slack" => /slack\.com/i,
      "github" => /api\.github\.com/i,
      "aws" => /\.amazonaws\.com/i,
      "google" => /googleapis\.com/i,
      "mailgun" => /api\.mailgun\.net/i,
      "postmark" => /api\.postmarkapp\.com/i,
      "braintree" => /api\.braintreegateway\.com/i,
      "paypal" => /api\.paypal\.com/i,
      "shopify" => /\.myshopify\.com|\.shopify\.com/i,
      "intercom" => /api\.intercom\.io/i,
      "segment" => /api\.segment\.io/i,
      "sentry" => /sentry\.io/i,
      "datadog" => /api\.datadoghq\.com/i,
      "plaid" => /\.plaid\.com/i,
    }.freeze

    def self.infer_vendor(host)
      return nil unless host

      VENDOR_PATTERNS.each do |vendor, pattern|
        return vendor if pattern.match?(host)
      end
      nil
    end

    def request(req, body = nil, &block)
      # Guard 1: skip if disabled
      return super unless OpenTrace.enabled?

      # Guard 2: skip if this IS an OpenTrace dispatch call (prevent infinite recursion)
      return super if Fiber[:opentrace_http_tracking_disabled]

      # Trace context injection is bookkeeping — must never raise to the host.
      begin
        inject_trace_context(req) if OpenTrace.config.trace_propagation
      rescue StandardError
      end

      start_time = Process.clock_gettime(Process::CLOCK_MONOTONIC)

      begin
        response = super
      rescue IOError, SystemCallError, OpenSSL::SSL::SSLError, Timeout::Error, Net::ProtocolError => e
        # Real network error from the host's HTTP call. Record it, then re-raise
        # so the host app sees the error it's expecting to handle.
        record_http_failure(req, e, start_time) rescue nil
        raise
      end

      # Bookkeeping for a successful response. Any bug here (NoMethodError on
      # a streaming body, a payload builder regression, etc.) must NOT bubble
      # into host code — swallow and move on.
      record_http_success(req, response, start_time) rescue nil

      response
    end

    private

    def record_http_success(req, response, start_time)
      duration_ms = (Process.clock_gettime(Process::CLOCK_MONOTONIC) - start_time) * 1000
      host = address
      port_str = (port == 443 || port == 80) ? "" : ":#{port}"
      scheme = use_ssl? ? "https" : "http"
      safe_path = req.path.to_s.split("?").first
      url = "#{scheme}://#{host}#{port_str}#{safe_path}"

      req_body = capturable_body(req.body)
      resp_body = capturable_body(response.body)
      resp_size = body_size(response)

      collector = Fiber[:opentrace_collector]
      if collector
        collector.record_http(
          method: req.method,
          url: url,
          host: host,
          status: response.code.to_i,
          duration_ms: duration_ms
        )
      end

      buffer = Fiber[:opentrace_buffer]
      if buffer
        vendor = OpenTrace::HttpTracker.infer_vendor(host)
        buffer.record_http(
          method: req.method,
          url: url,
          host: host,
          vendor: vendor,
          status: response.code.to_i,
          duration_ms: duration_ms,
          request_headers: nil,
          request_body: req_body,
          response_headers: nil,
          response_body: resp_body,
          response_size: resp_size,
          retry_attempt: 0,
          error_class: nil
        )
        buffer.record_timeline(type: :http, name: "#{req.method} #{host}", duration_ms: duration_ms)
      end
    end

    def record_http_failure(req, error, start_time)
      duration_ms = start_time ? (Process.clock_gettime(Process::CLOCK_MONOTONIC) - start_time) * 1000 : 0
      req_body = req ? capturable_body(req.body) : nil

      collector = Fiber[:opentrace_collector]
      if collector
        collector.record_http(
          method: req&.method,
          url: "#{address}#{req&.path}",
          host: address,
          status: 0,
          duration_ms: duration_ms,
          error: error.class.name
        )
      end

      buffer = Fiber[:opentrace_buffer]
      if buffer
        vendor = OpenTrace::HttpTracker.infer_vendor(address)
        buffer.record_http(
          method: req&.method,
          url: "#{address}#{req&.path}",
          host: address,
          vendor: vendor,
          status: 0,
          duration_ms: duration_ms,
          request_body: req_body,
          response_body: nil,
          response_size: nil,
          error_class: error.class.name
        )
      end
    end

    def capturable_body(body)
      return nil unless body.is_a?(String)
      return nil if body.bytesize >= MAX_BODY_CAPTURE_BYTES
      body
    end

    # Response body size when it can be determined without re-reading the stream.
    # Streaming responses (Net::ReadAdapter) can't be re-read, so we fall back
    # to Content-Length when present, otherwise nil.
    def body_size(response)
      return response.body.bytesize if response.body.is_a?(String)
      len = response["Content-Length"]
      len ? len.to_i : nil
    end

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
