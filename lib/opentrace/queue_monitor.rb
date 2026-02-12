# frozen_string_literal: true

module OpenTrace
  class QueueMonitor
    DEFAULT_INTERVAL = 60 # seconds

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
          report_queue_stats
        rescue Exception # rubocop:disable Lint/RescueException
          # Swallow
        end
      end
    end

    def stop
      @running = false
      @thread&.join(2)
    end

    private

    def report_queue_stats
      return unless OpenTrace.enabled?

      queues = collect_queue_data
      return if queues.nil? || queues.empty?

      total_enqueued = queues.values.sum { |q| q[:size] }

      metadata = {
        metric_type: "queue_depth",
        queues: queues,
        total_enqueued: total_enqueued,
        adapter: detect_adapter
      }

      level = total_enqueued > 1000 ? "WARN" : "INFO"
      summary = queues.map { |name, data| "#{name}=#{data[:size]}" }.join(", ")
      message = "Queue stats: #{summary}"

      OpenTrace.log(level, message, metadata)
    end

    def detect_adapter
      if defined?(::Sidekiq::Queue)
        "sidekiq"
      elsif defined?(::GoodJob::Job)
        "good_job"
      elsif defined?(::SolidQueue::ReadyExecution)
        "solid_queue"
      end
    end

    def collect_queue_data
      case detect_adapter
      when "sidekiq"     then sidekiq_stats
      when "good_job"    then good_job_stats
      when "solid_queue" then solid_queue_stats
      end
    rescue StandardError
      nil
    end

    def sidekiq_stats
      queues = {}
      Sidekiq::Queue.all.each do |queue|
        queues[queue.name] = {
          size: queue.size,
          latency_ms: (queue.latency * 1000).round(1)
        }
      end
      queues
    end

    def good_job_stats
      queues = {}
      GoodJob::Job.where(finished_at: nil)
                   .group(:queue_name)
                   .count
                   .each do |name, count|
        queues[name] = { size: count }
      end
      queues
    end

    def solid_queue_stats
      queues = {}
      SolidQueue::ReadyExecution.group(:queue_name)
                                 .count
                                 .each do |name, count|
        queues[name] = { size: count }
      end
      queues
    end
  end
end
