# frozen_string_literal: true

module OpenTrace
  class PoolMonitor
    DEFAULT_INTERVAL = 30 # seconds

    def initialize(interval: DEFAULT_INTERVAL)
      @interval = interval
      @thread = nil
      @running = false
    end

    def start
      return if @running
      @running = true

      @thread = Thread.new do
        Thread.current.report_on_exception = false
        loop do
          sleep @interval
          break unless @running
          report_pool_stats
        rescue Exception # rubocop:disable Lint/RescueException
          # Swallow — never crash the host app
        end
      end
    end

    def stop
      @running = false
      @thread&.join(2)
    end

    private

    def report_pool_stats
      return unless OpenTrace.enabled?
      return unless defined?(::ActiveRecord::Base)

      pool = ActiveRecord::Base.connection_pool
      stat = pool.stat

      metadata = {
        metric_type: "db_pool",
        pool_size: stat[:size],
        connections_busy: stat[:busy],
        connections_dead: stat[:dead],
        connections_idle: stat[:idle],
        threads_waiting: stat[:waiting],
        checkout_timeout: stat[:checkout_timeout]
      }

      level = stat[:waiting].to_i > 0 ? "WARN" : "DEBUG"
      message = "DB pool: #{stat[:busy]}/#{stat[:size]} busy, #{stat[:waiting]} waiting"

      OpenTrace.log(level, message, metadata)
    end
  end
end
