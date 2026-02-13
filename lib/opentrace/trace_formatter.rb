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

    # Delegate ActiveSupport::TaggedLogging::Formatter interface to the
    # original formatter so that Rails::Rack::Logger#push_tags works when
    # TraceFormatter replaces the logger's formatter.
    def push_tags(*tags)
      @original.push_tags(*tags) if @original.respond_to?(:push_tags)
    end

    def pop_tags(count = 1)
      @original.pop_tags(count) if @original.respond_to?(:pop_tags)
    end

    def current_tags
      if @original.respond_to?(:current_tags)
        @original.current_tags
      else
        []
      end
    end

    def tagged(*tags)
      if @original.respond_to?(:tagged)
        @original.tagged(*tags) { yield }
      else
        yield
      end
    end

    def clear_tags!
      @original.clear_tags! if @original.respond_to?(:clear_tags!)
    end

    def tags_text
      if @original.respond_to?(:tags_text)
        @original.tags_text
      else
        ""
      end
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
