# frozen_string_literal: true

module OpenTrace
  class Stats
    COUNTERS = %i[
      enqueued
      delivered
      dropped_queue_full
      dropped_circuit_open
      dropped_auth_suspended
      dropped_error
      retries
      rate_limited
      auth_failures
      payload_splits
      batches_sent
      bytes_sent
    ].freeze

    def initialize
      @counters = COUNTERS.each_with_object({}) { |k, h| h[k] = 0 }
      @mutex = Mutex.new
      @started_at = Time.now
    end

    def increment(counter, amount = 1)
      @mutex.synchronize { @counters[counter] += amount }
    end

    def get(counter)
      @mutex.synchronize { @counters[counter] }
    end

    def to_h
      @mutex.synchronize do
        @counters.merge(uptime_seconds: (Time.now - @started_at).to_i).dup
      end
    end

    def reset!
      @mutex.synchronize do
        @counters.transform_values! { 0 }
        @started_at = Time.now
      end
    end
  end
end
