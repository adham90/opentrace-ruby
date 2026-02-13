# frozen_string_literal: true

require "logger"

module OpenTrace
  # Minimal Logger-compatible class that forwards log messages to OpenTrace.
  # Designed to be used as a broadcast target with Rails 7.1+ BroadcastLogger.
  # Does NOT wrap another logger — its only job is to forward to OpenTrace.
  class LogForwarder < ::Logger
    SEVERITY_MAP = {
      ::Logger::DEBUG   => "DEBUG",
      ::Logger::INFO    => "INFO",
      ::Logger::WARN    => "WARN",
      ::Logger::ERROR   => "ERROR",
      ::Logger::FATAL   => "FATAL",
      ::Logger::UNKNOWN => "UNKNOWN"
    }.freeze

    def initialize
      super(nil)
      # Match OpenTrace's min_level so BroadcastLogger doesn't downgrade
      # the effective log level for the entire app. Without this, having
      # level=DEBUG here causes BroadcastLogger.level to drop to DEBUG,
      # which forces evaluation of all debug blocks and processing of all
      # debug messages across ALL broadcast targets — even in production.
      self.level = OpenTrace.config.logger_severity
    end

    def add(severity, message = nil, progname = nil, &block)
      severity ||= ::Logger::UNKNOWN
      return true if severity < level

      msg = resolve_message(message, progname, &block)
      return true if msg.nil? || (msg.is_a?(String) && msg.strip.empty?)

      level_str = SEVERITY_MAP.fetch(severity, "UNKNOWN")
      OpenTrace.log(level_str, msg.to_s)

      true
    rescue StandardError
      true
    end

    def close
      # no-op — nothing to close
    end

    # ActiveSupport::TaggedLogging interface — BroadcastLogger delegates
    # push_tags/pop_tags to ALL sinks. Without these, method_missing on
    # older Rails versions forwards blindly and raises NoMethodError.
    def push_tags(*); end
    def pop_tags(*); end

    def current_tags
      []
    end

    def tagged(*tags)
      yield self
    end

    private

    def resolve_message(message, progname, &block)
      if message.nil?
        block ? block.call : progname
      else
        message
      end
    end
  end
end
