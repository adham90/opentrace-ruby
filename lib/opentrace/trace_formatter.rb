# frozen_string_literal: true

module OpenTrace
  # Wraps an existing log formatter to inject trace context.
  # The injected context appears as a suffix: [trace_id=abc123 request_id=def456]
  #
  # Usage:
  #   Rails.logger.formatter = OpenTrace::TraceFormatter.new(Rails.logger.formatter)
  #
  class TraceFormatter
    def initialize(original_formatter = nil)
      @original = original_formatter || ::Logger::Formatter.new
    end

    def call(severity, datetime, progname, msg)
      formatted = @original.call(severity, datetime, progname, msg)
      trace_prefix = build_trace_prefix

      if trace_prefix && formatted.is_a?(String)
        # Append trace context before the trailing newline
        if formatted.end_with?("\n")
          "#{formatted.chomp} #{trace_prefix}\n"
        else
          "#{formatted} #{trace_prefix}"
        end
      else
        formatted
      end
    rescue StandardError
      formatted || @original.call(severity, datetime, progname, msg)
    end

    private

    def build_trace_prefix
      trace_id = Fiber[:opentrace_trace_id]
      return nil unless trace_id

      request_id = Fiber[:opentrace_request_id]
      parts = ["trace_id=#{trace_id}"]
      parts << "request_id=#{request_id}" if request_id
      "[#{parts.join(' ')}]"
    rescue StandardError
      nil
    end
  end
end
