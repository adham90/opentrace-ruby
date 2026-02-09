# frozen_string_literal: true

require_relative "opentrace/version"
require_relative "opentrace/config"
require_relative "opentrace/client"
require_relative "opentrace/logger"
require_relative "opentrace/log_forwarder"

module OpenTrace
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

      payload = {
        timestamp: Time.now.utc.strftime("%Y-%m-%dT%H:%M:%S.%6NZ"),
        level: level.to_s.upcase,
        service: config.service,
        environment: config.environment,
        message: message.to_s,
        metadata: metadata.is_a?(Hash) ? metadata : {}
      }

      # Include trace_id from metadata at top level if present
      if metadata.is_a?(Hash) && metadata[:trace_id]
        payload[:trace_id] = metadata.delete(:trace_id).to_s
      end

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

    def shutdown(timeout: 5)
      @client&.shutdown(timeout: timeout)
    end

    def reset!
      shutdown(timeout: 1)
      @config = nil
      @client = nil
    end

    private

    def client
      @client ||= Client.new(config)
    end

    def reset_client!
      @client&.shutdown(timeout: 1)
      @client = nil
    end
  end
end

# Auto-load Rails integration if Rails is present
require_relative "opentrace/rails" if defined?(::Rails::Railtie)
