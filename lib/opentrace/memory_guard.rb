# frozen_string_literal: true

module OpenTrace
  # Global memory guard that tracks total buffer usage across all concurrent
  # requests. When the global limit is exceeded, new requests fall back to
  # :minimal capture depth until memory drops.
  #
  # Also implements adaptive capture depth — monitors queue fill level and
  # auto-downgrades capture when the system is under pressure.
  class MemoryGuard
    CAPTURE_LEVELS = %i[none minimal standard full].freeze

    attr_reader :max_total_bytes, :pressure_threshold

    def initialize(max_total_bytes: 52_428_800, pressure_threshold: 0.8)
      @max_total_bytes    = max_total_bytes
      @pressure_threshold = pressure_threshold # 0.0-1.0, fraction of queue capacity
      @current_bytes      = 0
      @mutex              = Mutex.new
      @under_pressure     = false
    end

    # Called when a request buffer starts accumulating data.
    # Returns true if the allocation is allowed.
    def allocate(bytes)
      @mutex.synchronize do
        if @current_bytes + bytes > @max_total_bytes
          false
        else
          @current_bytes += bytes
          true
        end
      end
    end

    # Called when a request buffer is released (request ends).
    def release(bytes)
      @mutex.synchronize do
        @current_bytes = [0, @current_bytes - bytes].max
      end
    end

    # Current total bytes across all concurrent buffers.
    def current_bytes
      @mutex.synchronize { @current_bytes }
    end

    # Whether the global limit has been exceeded.
    def exceeded?
      @mutex.synchronize { @current_bytes >= @max_total_bytes }
    end

    # Update pressure state based on queue fill ratio (0.0-1.0).
    # Called periodically by the background thread.
    def update_pressure(queue_fill_ratio)
      @mutex.synchronize do
        @under_pressure = queue_fill_ratio >= @pressure_threshold
      end
    end

    # Whether the system is currently under pressure.
    def under_pressure?
      @mutex.synchronize { @under_pressure }
    end

    # Resolve the effective capture level, taking memory and pressure into account.
    # The configured level may be downgraded if the system is under stress.
    def effective_level(configured_level)
      @mutex.synchronize do
        if @current_bytes >= @max_total_bytes
          :minimal
        elsif @under_pressure
          downgrade(configured_level)
        else
          configured_level
        end
      end
    end

    # Reset state (for testing).
    def reset!
      @mutex.synchronize do
        @current_bytes  = 0
        @under_pressure = false
      end
    end

    def stats
      @mutex.synchronize do
        {
          current_bytes: @current_bytes,
          max_total_bytes: @max_total_bytes,
          usage_pct: @max_total_bytes > 0 ? ((@current_bytes.to_f / @max_total_bytes) * 100).round(1) : 0.0,
          under_pressure: @under_pressure
        }
      end
    end

    private

    # Downgrade one level (e.g., :full → :standard, :standard → :minimal)
    def downgrade(level)
      idx = CAPTURE_LEVELS.index(level) || 3
      CAPTURE_LEVELS[[idx - 1, 0].max]
    end
  end
end
