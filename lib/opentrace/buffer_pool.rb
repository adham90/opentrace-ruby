# frozen_string_literal: true

require_relative "request_buffer"

module OpenTrace
  class BufferPool
    def initialize(size: 32, max_buffer_bytes: 1_048_576, max_audit_events: 50)
      @max_buffer_bytes = max_buffer_bytes
      @max_audit_events = max_audit_events
      @max_size = size

      @mutex = Mutex.new
      @pool  = Array.new(size) { RequestBuffer.new(max_buffer_bytes: max_buffer_bytes, max_audit_events: max_audit_events) }
      @checked_out = 0
    end

    # Returns a RequestBuffer ready for use. Pulls from pool if available,
    # allocates a new one if pool is empty. Sets id and started_at.
    def checkout
      buffer = @mutex.synchronize do
        buf = @pool.pop
        @checked_out += 1
        buf
      end

      # Pool was empty — allocate fresh (outside the lock)
      buffer ||= RequestBuffer.new(max_buffer_bytes: @max_buffer_bytes, max_audit_events: @max_audit_events)

      buffer.id = ULID.generate
      buffer.started_at = Process.clock_gettime(Process::CLOCK_MONOTONIC)

      buffer
    end

    # Resets the buffer and returns it to the pool. If the pool is already
    # at max capacity, the buffer is discarded (GC will collect it).
    def checkin(buffer)
      buffer.reset!

      @mutex.synchronize do
        @checked_out -= 1
        @checked_out = 0 if @checked_out < 0 # safety clamp

        if @pool.size < @max_size
          @pool.push(buffer)
        end
        # else: discard — pool is full
      end
    end

    # Returns a snapshot of pool statistics.
    def stats
      @mutex.synchronize do
        {
          pool_size: @max_size,
          available: @pool.size,
          checked_out: @checked_out
        }
      end
    end
  end
end
