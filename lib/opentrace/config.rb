# frozen_string_literal: true

module OpenTrace
  class Config
    REQUIRED_FIELDS = %i[endpoint api_key service].freeze
    LEVELS = { debug: 0, info: 1, warn: 2, error: 3, fatal: 4 }.freeze

    attr_accessor :endpoint, :api_key, :service, :environment, :timeout, :enabled,
                  :context, :min_level, :hostname, :pid, :git_sha,
                  :batch_size, :flush_interval,
                  :sql_logging, :sql_duration_threshold_ms,
                  :ignore_paths,
                  :pool_monitoring, :pool_monitoring_interval,
                  :queue_monitoring, :queue_monitoring_interval,
                  :request_summary, :timeline, :timeline_max_events

    def initialize
      @endpoint    = nil
      @api_key     = nil
      @service     = nil
      @environment = nil
      @timeout     = 1.0
      @enabled     = true
      @context     = nil    # nil | Hash | Proc
      @min_level   = :debug # send everything by default
      @hostname       = nil
      @pid            = nil
      @git_sha        = nil
      @batch_size     = 50
      @flush_interval = 5.0
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
  end
end
