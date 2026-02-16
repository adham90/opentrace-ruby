# frozen_string_literal: true

module OpenTrace
  # Rails 7.0+ Error Reporter subscriber.
  #
  # Captures ALL exceptions reported via Rails.error (including those
  # rescued by rescue_from in controllers). This fills the gap where
  # process_action.action_controller only includes exception data for
  # unhandled exceptions — rescued exceptions show status 500 but no
  # exception_class, backtrace, or error_fingerprint.
  #
  # Registered automatically in the Railtie when Rails.error is available.
  class ErrorSubscriber
    SEVERITY_MAP = {
      error: "ERROR",
      warning: "WARN",
      info: "INFO"
    }.freeze

    def report(error, handled:, severity:, context: {}, source: nil)
      return unless OpenTrace.enabled?

      # Skip if already inside an OpenTrace logging call (re-entrance guard)
      return if Fiber[:opentrace_logging]

      level = SEVERITY_MAP[severity] || "ERROR"

      meta = {}
      meta[:exception_class] = error.class.name
      meta[:exception_message] = error.message&.slice(0, 500)
      meta[:handled] = handled
      meta[:error_source] = source if source

      if error.backtrace
        cleaned = clean_backtrace(error.backtrace)
        meta[:backtrace] = cleaned.first(15)
        meta[:error_fingerprint] = OpenTrace.send(:compute_error_fingerprint, error.class.name, cleaned)
      end

      # Capture exception cause chain
      if error.cause
        meta[:exception_causes] = OpenTrace.send(:build_cause_chain, error.cause, depth: 0)
      end

      # Include request params from context if available
      if context[:params].is_a?(Hash)
        params = context[:params].except("controller", "action")
        meta[:params] = truncate_hash(params, 2048) unless params.empty?
      end

      # Include controller/action context
      meta[:controller] = context[:controller] if context[:controller]
      meta[:action] = context[:action] if context[:action]

      # Merge any additional context from the reporter
      context.each do |k, v|
        next if %i[params controller action].include?(k)
        meta[k] = v
      end

      OpenTrace.log(level, "#{error.class}: #{error.message&.slice(0, 200)}", meta)
    rescue StandardError
      # Never raise to the host app
    end

    private

    def clean_backtrace(backtrace)
      if defined?(::Rails) && ::Rails.respond_to?(:backtrace_cleaner)
        ::Rails.backtrace_cleaner.clean(backtrace)
      else
        backtrace.reject { |line| line.include?("/gems/") }
      end
    end

    def truncate_hash(hash, max_bytes)
      json = JSON.generate(hash)
      return hash if json.bytesize <= max_bytes
      { _truncated: true, _size: json.bytesize }
    rescue StandardError
      { _truncated: true }
    end
  end
end
