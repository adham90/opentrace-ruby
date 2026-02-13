# frozen_string_literal: true

module OpenTrace
  class Config
    REQUIRED_FIELDS = %i[endpoint api_key service].freeze
    LEVELS = { debug: 0, info: 1, warn: 2, error: 3, fatal: 4 }.freeze
    LEVEL_INTS = { "DEBUG" => 0, "INFO" => 1, "WARN" => 2, "ERROR" => 3, "FATAL" => 4 }.freeze

    attr_accessor :endpoint, :api_key, :service, :environment, :timeout, :enabled,
                  :context, :hostname, :pid, :git_sha,
                  :batch_size, :flush_interval,
                  :max_retries, :retry_base_delay, :retry_max_delay,
                  :circuit_breaker_threshold, :circuit_breaker_timeout,
                  :rate_limit_backoff,
                  :on_drop,
                  :compression, :compression_threshold,
                  :sql_logging, :sql_duration_threshold_ms,
                  :pool_monitoring, :pool_monitoring_interval,
                  :queue_monitoring, :queue_monitoring_interval,
                  :request_summary, :timeline, :timeline_max_events,
                  :memory_tracking, :http_tracking,
                  :max_payload_bytes,
                  :trace_propagation,
                  :log_forwarding, :view_tracking, :cache_tracking,
                  :deprecation_tracking, :detailed_request_log,
                  :sample_rate, :sampler, :before_send,
                  :sql_normalization, :log_trace_injection,
                  :source_context, :before_breadcrumb,
                  :pii_scrubbing, :pii_patterns, :pii_disabled_patterns,
                  :session_tracking,
                  :on_error, :after_send,
                :transport, :socket_path,
                :local_vars_capture,
                :explain_slow_queries, :explain_threshold_ms,
                :runtime_metrics, :runtime_metrics_interval

    # Custom writers that invalidate the level cache
    attr_reader :min_level, :allowed_levels, :ignore_paths

    def min_level=(val)
      @min_level = val
      @level_cache = nil
    end

    def allowed_levels=(val)
      @allowed_levels = val
      @level_cache = nil
    end

    def ignore_paths=(val)
      @ignore_paths = val
    end

    def initialize
      @endpoint    = nil
      @api_key     = nil
      @service     = nil
      @environment = nil
      @timeout     = 1.0
      @enabled     = true
      @context     = nil    # nil | Hash | Proc
      @min_level   = :info
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
      @sql_logging    = false
      @sql_duration_threshold_ms = 0.0
      @ignore_paths   = %w[/up /health /healthz /ping /ready /livez /readyz]
      @pool_monitoring = false
      @pool_monitoring_interval = 30
      @queue_monitoring = false
      @queue_monitoring_interval = 60
      @request_summary = true
      @timeline = false
      @timeline_max_events = 200
      @memory_tracking = false
      @http_tracking = false
      @max_payload_bytes = 262_144 # 256 KB
      @trace_propagation = true
      @log_forwarding = false
      @view_tracking = false
      @cache_tracking = false
      @deprecation_tracking = false
      @detailed_request_log = false
      @sample_rate = 1.0     # Float 0.0-1.0, default 1.0 (all requests)
      @sampler     = nil     # Proc(env) -> Float, for per-endpoint rates
      @before_send = nil     # Proc(payload) -> payload|nil, filter/drop
      @sql_normalization = true   # Normalize SQL queries (replace literals with ?)
      @log_trace_injection = false # Inject trace_id/request_id into Rails logger
      @source_context = false      # Capture source code context around errors
      @before_breadcrumb = nil     # Proc(Breadcrumb) -> Breadcrumb|nil
      @pii_scrubbing = false       # Scrub PII from metadata before sending
      @pii_patterns = nil          # Array of additional Regexp patterns
      @pii_disabled_patterns = nil # Array of Symbol pattern names to skip
      @session_tracking = false    # Extract session ID from cookies
      @on_error = nil              # Proc(exception, metadata) — called on error capture
      @after_send = nil            # Proc(batch_size, bytes) — called after successful delivery
      @transport = :http              # :http | :unix_socket
      @socket_path = "/tmp/opentrace.sock" # Unix socket path
      @local_vars_capture = false     # Capture local variables via explicit binding
      @explain_slow_queries = false   # Run EXPLAIN on slow SQL queries
      @explain_threshold_ms = 100.0   # Threshold for EXPLAIN capture
      @runtime_metrics = false        # Collect GC/runtime metrics
      @runtime_metrics_interval = 30  # Interval in seconds
      @level_cache = nil
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

    # Hot path: single hash lookup, zero allocations for known levels.
    # Cache is built lazily on first call and invalidated when
    # min_level or allowed_levels change.
    def level_allowed?(level)
      cache = @level_cache
      unless cache
        build_level_cache!
        cache = @level_cache
      end
      key = level.to_s.upcase
      result = cache[key]
      return result unless result.nil?
      # Unknown level (e.g. "UNKNOWN"): treat as severity 0
      return false if allowed_levels # not in the allowed list
      0 >= (LEVELS[min_level.to_s.downcase.to_sym] || 0)
    end

    # Pre-compute the level cache. Called at end of configure block
    # and lazily when settings change afterward.
    def finalize!
      build_level_cache!
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

    private

    def build_level_cache!
      min_int = LEVELS[min_level.to_s.downcase.to_sym] || 0
      if allowed_levels
        @level_cache = allowed_levels.each_with_object({}) do |l, h|
          h[l.to_s.upcase] = true
        end.freeze
      else
        @level_cache = LEVEL_INTS.each_with_object({}) do |(k, v), h|
          h[k] = v >= min_int
        end.freeze
      end
    end
  end
end
