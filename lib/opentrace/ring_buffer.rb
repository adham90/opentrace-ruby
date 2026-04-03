# frozen_string_literal: true

module OpenTrace
  class RingBuffer
    DEFAULT_CAPACITY  = 1024
    DEFAULT_MAX_BYTES = 10_485_760 # 10 MB
    DEFAULT_ITEM_BYTE_SIZE = 1024  # 1 KB estimate per item

    attr_reader :capacity, :max_bytes

    def initialize(capacity: DEFAULT_CAPACITY, max_bytes: DEFAULT_MAX_BYTES)
      @capacity  = capacity
      @max_bytes = max_bytes
      @buffer    = Array.new(capacity)
      @sizes     = Array.new(capacity, 0)
      @head      = 0 # next write position
      @tail      = 0 # next read position
      @count     = 0
      @byte_size = 0
      @closed    = false
      @mutex     = Mutex.new
      @not_empty = ConditionVariable.new
    end

    # Non-blocking push. Returns true if enqueued, false if full, closed, or
    # max_bytes would be exceeded.
    def push(item, byte_size: DEFAULT_ITEM_BYTE_SIZE)
      @mutex.synchronize do
        return false if @closed
        return false if @count >= @capacity
        return false if @byte_size + byte_size > @max_bytes

        @buffer[@head] = item
        @sizes[@head]  = byte_size
        @head = (@head + 1) % @capacity
        @count += 1
        @byte_size += byte_size

        @not_empty.signal
        true
      end
    end

    # Blocking pop. Waits until an item is available. Returns nil when closed
    # and the buffer is empty.
    def pop
      @mutex.synchronize do
        while @count == 0
          return nil if @closed
          @not_empty.wait(@mutex)
        end

        item = @buffer[@tail]
        item_size = @sizes[@tail]
        @buffer[@tail] = nil
        @sizes[@tail]  = 0
        @tail = (@tail + 1) % @capacity
        @count -= 1
        @byte_size -= item_size

        item
      end
    end

    # Drains up to +max+ items at once. Returns an empty array when closed and
    # the buffer is empty.
    def pop_batch(max)
      @mutex.synchronize do
        while @count == 0
          return [] if @closed
          @not_empty.wait(@mutex)
        end

        n = [max, @count].min
        items = Array.new(n)

        n.times do |i|
          items[i] = @buffer[@tail]
          @byte_size -= @sizes[@tail]
          @buffer[@tail] = nil
          @sizes[@tail]  = 0
          @tail = (@tail + 1) % @capacity
          @count -= 1
        end

        items
      end
    end

    # Current number of items in the buffer.
    def size
      @mutex.synchronize { @count }
    end

    # Total estimated bytes of items currently in the buffer.
    def byte_size
      @mutex.synchronize { @byte_size }
    end

    def full?
      @mutex.synchronize { @count >= @capacity }
    end

    def empty?
      @mutex.synchronize { @count == 0 }
    end

    # Empties the buffer and resets byte tracking.
    def clear
      @mutex.synchronize do
        @buffer.fill(nil)
        @sizes.fill(0)
        @head = 0
        @tail = 0
        @count = 0
        @byte_size = 0
      end
    end

    # Signals consumers to stop. After close, push returns false and pop/
    # pop_batch return nil/[] once the buffer is drained.
    def close
      @mutex.synchronize do
        @closed = true
        @not_empty.broadcast
      end
    end

    def closed?
      @mutex.synchronize { @closed }
    end
  end
end
