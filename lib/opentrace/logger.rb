# frozen_string_literal: true

require "logger"

module OpenTrace
  class Logger < ::Logger
    SEVERITY_MAP = {
      ::Logger::DEBUG   => "DEBUG",
      ::Logger::INFO    => "INFO",
      ::Logger::WARN    => "WARN",
      ::Logger::ERROR   => "ERROR",
      ::Logger::FATAL   => "FATAL",
      ::Logger::UNKNOWN => "UNKNOWN"
    }.freeze

    attr_reader :wrapped_logger

    def initialize(wrapped_logger, metadata: {})
      @wrapped_logger = wrapped_logger
      @default_metadata = metadata
      # Initialize with nil logdev - we override #add to handle output
      super(nil)
      self.level = wrapped_logger.level if wrapped_logger.respond_to?(:level)
    end

    def add(severity, message = nil, progname = nil, &block)
      # Delegate to wrapped logger first (synchronous, as required)
      @wrapped_logger.add(severity, message, progname, &block)

      # Forward to OpenTrace, never raise
      forward_to_opentrace(severity, message, progname, &block)

      true
    rescue StandardError
      # Never raise to the host app
      true
    end

    # Support TaggedLogging if the wrapped logger uses it
    def tagged(*tags, &block)
      if @wrapped_logger.respond_to?(:tagged)
        @wrapped_logger.tagged(*tags) do
          @current_tags = current_tags_from_wrapped
          block.call(self)
        end
      else
        block.call(self)
      end
    rescue StandardError
      block.call(self)
    end

    def flush
      @wrapped_logger.flush if @wrapped_logger.respond_to?(:flush)
    end

    def close
      @wrapped_logger.close if @wrapped_logger.respond_to?(:close)
    end

    # Proxy formatter to wrapped logger
    def formatter
      if @wrapped_logger.respond_to?(:formatter)
        @wrapped_logger.formatter
      else
        super
      end
    end

    def formatter=(f)
      if @wrapped_logger&.respond_to?(:formatter=)
        @wrapped_logger.formatter = f
      else
        super
      end
    end

    private

    def forward_to_opentrace(severity, message, progname, &block)
      return unless OpenTrace.enabled?

      msg = resolve_message(message, progname, &block)
      return if msg.nil? || (msg.is_a?(String) && msg.strip.empty?)

      level_str = SEVERITY_MAP.fetch(severity || ::Logger::UNKNOWN, "UNKNOWN")

      metadata = @default_metadata.dup
      tags = current_tags_from_wrapped
      metadata[:tags] = tags if tags && !tags.empty?

      OpenTrace.log(level_str, msg.to_s, metadata)
    rescue StandardError
      # Swallow - never affect the host app
    end

    def resolve_message(message, progname, &block)
      if message.nil?
        if block
          block.call
        else
          progname
        end
      else
        message
      end
    end

    def current_tags_from_wrapped
      if @wrapped_logger.respond_to?(:formatter) &&
         @wrapped_logger.formatter.respond_to?(:current_tags)
        @wrapped_logger.formatter.current_tags.dup
      end
    rescue StandardError
      nil
    end
  end
end
