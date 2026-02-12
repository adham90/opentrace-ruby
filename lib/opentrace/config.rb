# frozen_string_literal: true

module OpenTrace
  class Config
    REQUIRED_FIELDS = %i[endpoint api_key service].freeze
    LEVELS = { debug: 0, info: 1, warn: 2, error: 3, fatal: 4 }.freeze

    attr_accessor :endpoint, :api_key, :service, :environment, :timeout, :enabled,
                  :context, :min_level, :allowed_levels, :hostname, :pid, :git_sha,
                  :batch_size, :flush_interval,
                  :max_retries, :retry_base_delay, :retry_max_delay,
                  :circuit_breaker_threshold, :circuit_breaker_timeout,
                  :rate_limit_backoff,
                  :on_drop,
                  :compression, :compression_threshold,
                  :sql_logging, :sql_duration_threshold_ms,
                  :ignore_paths,
                  :pool_monitoring, :pool_monitoring_interval,
                  :queue_monitoring, :queue_monitoring_interval,
                  :request_summary, :timeline, :timeline_max_events,
                  :memory_tracking, :http_tracking,
                  :max_payload_bytes,
                  :trace_propagation

    def initialize
      @endpoint    = nil
      @api_key     = nil
      @service     = nil
      @environment = nil
      @timeout     = 1.0
      @enabled     = true
      @context     = nil    # nil | Hash | Proc
      @min_level   = :debug # send everything by default
      @allowed_levels = nil  # nil = use min_level threshold (backward compatible)
      @hostname       = nil
      @pid            = nil
      @git_sha        = nil
      @batch_size     = 50
      @flush_interval = 5.0
      @max_retries    = 2
      @retry_base_delay = 0.1
      @retry_max_delay  = 2.0
      @circuit_breaker_threshold = 5
      @circuit_breaker_timeout   = 30
      @rate_limit_backoff = 5.0
      @on_drop        = nil # ->(count, reason) { ... }
      @compression    = true
      @compression_threshold = 1024 # only compress payloads > 1KB
      @sql_logging    = true
      @sql_duration_threshold_ms = 0.0
      @ignore_paths   = []
      @pool_monitoring = false
      @pool_monitoring_interval = 30
      @queue_monitoring = false
      @queue_monitoring_interval = 60
      @request_summary = true
      @timeline = true
      @timeline_max_events = 200
      @memory_tracking = false
      @http_tracking = false
      @max_payload_bytes = 262_144 # 256 KB
      @trace_propagation = true
    end

    def valid?
      REQUIRED_FIELDS.all? { |f| value = send(f); value.is_a?(String) && !value.empty? }
    end

    def enabled?
      @enabled && valid?
    end

    def min_level_value
      LEVELS[min_level.to_s.downcase.to_sym] || 0
    end

    def level_allowed?(level)
      if allowed_levels
        allowed_levels.map { |l| l.to_s.upcase }.include?(level.to_s.upcase)
      else
        (LEVELS[level.to_s.downcase.to_sym] || 0) >= min_level_value
      end
    end

    # Maps OpenTrace min_level to Ruby Logger severity constant.
    # Used by LogForwarder to set its level so BroadcastLogger
    # doesn't downgrade the effective log level for the entire app.
    LEVEL_TO_LOGGER_SEVERITY = {
      debug: 0, # ::Logger::DEBUG
      info:  1, # ::Logger::INFO
      warn:  2, # ::Logger::WARN
      error: 3, # ::Logger::ERROR
      fatal: 4  # ::Logger::FATAL
    }.freeze

    def logger_severity
      LEVEL_TO_LOGGER_SEVERITY[min_level.to_s.downcase.to_sym] || 0
    end
  end
end
