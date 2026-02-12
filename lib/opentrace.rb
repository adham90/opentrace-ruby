# frozen_string_literal: true

require "socket"
require "digest"
require_relative "opentrace/version"
require_relative "opentrace/config"
require_relative "opentrace/circuit_breaker"
require_relative "opentrace/client"
require_relative "opentrace/logger"
require_relative "opentrace/log_forwarder"
require_relative "opentrace/middleware"

module OpenTrace
  LEVEL_VALUES = { "DEBUG" => 0, "INFO" => 1, "WARN" => 2, "ERROR" => 3, "FATAL" => 4 }.freeze

  class << self
    def configure
      yield config
      reset_client!
    end

    def config
      @config ||= Config.new
    end

    def log(level, message, metadata = {})
      return unless enabled?
      return unless level_meets_threshold?(level)

      # 1. Start with user-defined context (lowest priority)
      meta = resolve_context

      # 2. Merge caller-provided metadata (overrides context)
      meta.merge!(metadata) if metadata.is_a?(Hash)

      # 3. Static context — only fills in keys not already set
      static_context.each { |k, v| meta[k] ||= v }

      # 4. Request ID from middleware (if not already set by caller or context)
      meta[:request_id] ||= current_request_id if current_request_id

      # Extract trace_id to top level before building payload
      trace_id = meta.delete(:trace_id)

      payload = {
        timestamp: Time.now.utc.strftime("%Y-%m-%dT%H:%M:%S.%6NZ"),
        level: level.to_s.upcase,
        service: config.service,
        environment: config.environment,
        message: message.to_s,
        metadata: meta.compact
      }

      payload[:trace_id] = trace_id.to_s if trace_id

      client.enqueue(payload)
    rescue StandardError
      # Never raise to the host app
    end

    def error(exception, metadata = {})
      return unless enabled?

      meta = metadata.is_a?(Hash) ? metadata.dup : {}
      meta[:exception_class]   = exception.class.name
      meta[:exception_message] = exception.message&.slice(0, 500)

      if exception.backtrace
        cleaned = if defined?(::Rails) && ::Rails.respond_to?(:backtrace_cleaner)
                    ::Rails.backtrace_cleaner.clean(exception.backtrace)
                  else
                    exception.backtrace.reject { |l| l.include?("/gems/") }
                  end
        meta[:backtrace] = cleaned.first(15)
        meta[:error_fingerprint] = compute_error_fingerprint(exception.class.name, cleaned)
      end

      log("ERROR", exception.message.to_s, meta)
    rescue StandardError
      # Never raise to the host app
    end

    def event(event_type, message, metadata = {})
      return unless enabled?

      meta = resolve_context
      meta.merge!(metadata) if metadata.is_a?(Hash)
      static_context.each { |k, v| meta[k] ||= v }
      meta[:request_id] ||= current_request_id if current_request_id

      trace_id = meta.delete(:trace_id)

      payload = {
        timestamp: Time.now.utc.strftime("%Y-%m-%dT%H:%M:%S.%6NZ"),
        level: "INFO",
        event_type: event_type.to_s,
        service: config.service,
        environment: config.environment,
        message: message.to_s,
        metadata: meta.compact
      }
      payload[:trace_id] = trace_id.to_s if trace_id

      client.enqueue(payload)
    rescue StandardError
      # Never raise to the host app
    end

    def enabled?
      config.enabled?
    end

    def disable!
      config.enabled = false
    end

    def enable!
      config.enabled = true
    end

    def current_request_id
      Fiber[:opentrace_request_id]
    end

    def current_request_id=(id)
      Fiber[:opentrace_request_id] = id
    end

    def shutdown(timeout: 5)
      @client&.shutdown(timeout: timeout)
    end

    def reset!
      shutdown(timeout: 1)
      @config = nil
      @client = nil
      @static_context = nil
      @at_exit_registered = nil
    end

    private

    def client
      @client ||= begin
        c = Client.new(config)
        register_at_exit_hook!
        c
      end
    end

    def register_at_exit_hook!
      return if @at_exit_registered
      @at_exit_registered = true
      at_exit { OpenTrace.shutdown(timeout: 2) }
    end

    def reset_client!
      @client&.shutdown(timeout: 1)
      @client = nil
      @static_context = nil
    end

    def level_meets_threshold?(level)
      config.level_allowed?(level)
    end

    def static_context
      @static_context ||= {
        hostname: config.hostname || Socket.gethostname,
        pid: config.pid || Process.pid,
        git_sha: config.git_sha || ENV["REVISION"] || ENV["GIT_SHA"] || ENV["HEROKU_SLUG_COMMIT"]
      }.compact
    rescue StandardError
      {}
    end

    def compute_error_fingerprint(exception_class, backtrace)
      origin = if backtrace.is_a?(Array)
                 backtrace.find { |l| l.include?("app/") || l.include?("lib/") } || backtrace.first
               end
      normalized_origin = origin&.gsub(/:\d+:/, ":") || "unknown"
      Digest::MD5.hexdigest("#{exception_class}||#{normalized_origin}")[0, 12]
    rescue StandardError
      nil
    end

    def resolve_context
      ctx = case config.context
            when Proc then config.context.call
            when Hash then config.context
            end
      ctx.is_a?(Hash) ? ctx.dup : {}
    rescue StandardError
      {} # Broken proc? Swallow, never crash.
    end
  end
end

# Auto-load Rails integration if Rails is present
require_relative "opentrace/rails" if defined?(::Rails::Railtie)
