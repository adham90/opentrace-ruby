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
    def clear_tags!; end

    def current_tags
      []
    end

    def tags_text
      ""
    end

    # DO NOT implement `tagged` here.
    #
    # Rails' ActiveSupport::BroadcastLogger routes `tagged` through
    # `method_missing` (it's not in LOGGER_METHODS), which calls
    # `logger.send(:tagged, *tags, &block)` on EVERY sink that responds to
    # `:tagged` — without the block-cache guard that `dispatch` uses for
    # info/debug/warn/etc. So if LogForwarder implements `tagged(*tags) { yield self }`,
    # the block passed to the BroadcastLogger's tagged call runs ONCE PER
    # SINK. For ActiveJob — which wraps both `around_enqueue` and
    # `around_perform` in `logger.tagged(...) { ... }` — that means:
    #   * enqueue flow runs twice  → adapter.enqueue fires twice
    #   * each dispatched perform runs twice
    #   * net effect: 4 performs (and 4 add_assistant_message rows) per
    #     single perform_later call on a BroadcastLogger with 2 sinks.
    #
    # By simply NOT responding to `:tagged`, BroadcastLogger's
    # method_missing does `@broadcasts.select { |l| l.respond_to?(name) }`
    # and filters us out — only the real TaggedLogging sink receives the
    # call, its block yields exactly once, and dispatch is single.
    # `push_tags` / `pop_tags` / `clear_tags!` DO stay defined as no-ops
    # because they never take blocks, so calling them on every sink is
    # harmless.

    def flush; end

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
