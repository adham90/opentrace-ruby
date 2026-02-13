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
      dropped_filtered
      retries
      rate_limited
      auth_failures
      payload_splits
      batches_sent
      bytes_sent
      sampled_out
      sql_filtered
    ].freeze

    def initialize
      @counters = COUNTERS.each_with_object(Hash.new(0)) { |k, h| h[k] = 0 }
      @mutex = Mutex.new
      @started_at = Time.now
    end

    # Hot path: no mutex. Under CRuby's GIL, Hash#[]= with integer
    # increment is effectively atomic for single operations.
    def increment(counter, amount = 1)
      @counters[counter] += amount
    end

    def get(counter)
      @counters[counter]
    end

    # Cold path: mutex for consistent snapshot
    def to_h
      @mutex.synchronize do
        @counters.merge(uptime_seconds: (Time.now - @started_at).to_i).dup
      end
    end

    def reset!
      @mutex.synchronize do
        @counters = Hash.new(0)
        @started_at = Time.now
      end
    end
  end
end
