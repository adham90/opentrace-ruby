# frozen_string_literal: true

require "opentrace/ring_buffer"

RSpec.describe OpenTrace::RingBuffer do
  subject(:buffer) { described_class.new(capacity: 4, max_bytes: 4096) }

  describe "#push and #pop" do
    it "pushes and pops a single item" do
      expect(buffer.push(:a, byte_size: 100)).to be true
      expect(buffer.pop).to eq(:a)
    end

    it "maintains FIFO order" do
      buffer.push(:a, byte_size: 100)
      buffer.push(:b, byte_size: 100)
      buffer.push(:c, byte_size: 100)
      expect(buffer.pop).to eq(:a)
      expect(buffer.pop).to eq(:b)
      expect(buffer.pop).to eq(:c)
    end
  end

  describe "#pop_batch" do
    it "drains up to max items" do
      buffer.push(:a, byte_size: 100)
      buffer.push(:b, byte_size: 100)
      buffer.push(:c, byte_size: 100)

      items = buffer.pop_batch(2)
      expect(items).to eq([:a, :b])
      expect(buffer.size).to eq(1)
    end

    it "drains all items when max exceeds count" do
      buffer.push(:a, byte_size: 100)
      buffer.push(:b, byte_size: 100)

      items = buffer.pop_batch(10)
      expect(items).to eq([:a, :b])
      expect(buffer.empty?).to be true
    end
  end

  describe "#push when full" do
    it "returns false when capacity is reached" do
      4.times { |i| expect(buffer.push(i, byte_size: 100)).to be true }
      expect(buffer.push(:overflow, byte_size: 100)).to be false
      expect(buffer.size).to eq(4)
    end
  end

  describe "#push when max_bytes exceeded" do
    it "returns false when adding the item would exceed max_bytes" do
      small_buffer = described_class.new(capacity: 100, max_bytes: 500)
      expect(small_buffer.push(:a, byte_size: 300)).to be true
      expect(small_buffer.push(:b, byte_size: 300)).to be false
      expect(small_buffer.size).to eq(1)
    end

    it "accepts items again after popping frees byte budget" do
      small_buffer = described_class.new(capacity: 100, max_bytes: 500)
      small_buffer.push(:a, byte_size: 300)
      small_buffer.push(:b, byte_size: 300) # rejected
      small_buffer.pop
      expect(small_buffer.push(:c, byte_size: 300)).to be true
    end
  end

  describe "#size" do
    it "tracks correctly after push and pop" do
      expect(buffer.size).to eq(0)
      buffer.push(:a, byte_size: 100)
      buffer.push(:b, byte_size: 100)
      expect(buffer.size).to eq(2)
      buffer.pop
      expect(buffer.size).to eq(1)
      buffer.pop
      expect(buffer.size).to eq(0)
    end

    it "tracks correctly after pop_batch" do
      3.times { |i| buffer.push(i, byte_size: 100) }
      buffer.pop_batch(2)
      expect(buffer.size).to eq(1)
    end
  end

  describe "#full? and #empty?" do
    it "reports empty on fresh buffer" do
      expect(buffer.empty?).to be true
      expect(buffer.full?).to be false
    end

    it "reports full at capacity" do
      4.times { |i| buffer.push(i, byte_size: 100) }
      expect(buffer.full?).to be true
      expect(buffer.empty?).to be false
    end
  end

  describe "#pop blocks until item available" do
    it "blocks and then returns the item pushed from another thread" do
      result = nil
      consumer = Thread.new { result = buffer.pop }

      # Give the consumer thread time to block
      sleep(0.05)
      expect(consumer.alive?).to be true

      buffer.push(:delayed, byte_size: 100)
      consumer.join(2)

      expect(result).to eq(:delayed)
    end
  end

  describe "#pop_batch blocks until item available" do
    it "blocks and then returns items pushed from another thread" do
      result = nil
      consumer = Thread.new { result = buffer.pop_batch(5) }

      sleep(0.05)
      expect(consumer.alive?).to be true

      buffer.push(:x, byte_size: 100)
      buffer.push(:y, byte_size: 100)
      consumer.join(2)

      # pop_batch wakes once at least one item is available and drains what it can
      expect(result).to include(:x)
      expect(result.length).to be >= 1
    end
  end

  describe "#close" do
    it "makes pop return nil when buffer is empty" do
      buffer.close
      expect(buffer.pop).to be_nil
    end

    it "makes pop_batch return empty array when buffer is empty" do
      buffer.close
      expect(buffer.pop_batch(10)).to eq([])
    end

    it "still allows draining remaining items before returning nil" do
      buffer.push(:a, byte_size: 100)
      buffer.push(:b, byte_size: 100)
      buffer.close

      expect(buffer.pop).to eq(:a)
      expect(buffer.pop).to eq(:b)
      expect(buffer.pop).to be_nil
    end

    it "makes push return false" do
      buffer.close
      expect(buffer.push(:a, byte_size: 100)).to be false
    end

    it "wakes blocked pop threads" do
      result = :not_set
      consumer = Thread.new { result = buffer.pop }

      sleep(0.05)
      buffer.close
      consumer.join(2)

      expect(result).to be_nil
    end

    it "wakes blocked pop_batch threads" do
      result = :not_set
      consumer = Thread.new { result = buffer.pop_batch(5) }

      sleep(0.05)
      buffer.close
      consumer.join(2)

      expect(result).to eq([])
    end
  end

  describe "#clear" do
    it "empties the buffer and resets byte_size" do
      buffer.push(:a, byte_size: 200)
      buffer.push(:b, byte_size: 300)
      expect(buffer.size).to eq(2)
      expect(buffer.byte_size).to eq(500)

      buffer.clear
      expect(buffer.size).to eq(0)
      expect(buffer.byte_size).to eq(0)
      expect(buffer.empty?).to be true
    end

    it "allows pushing again after clear" do
      4.times { |i| buffer.push(i, byte_size: 100) }
      expect(buffer.full?).to be true

      buffer.clear
      expect(buffer.push(:fresh, byte_size: 100)).to be true
      expect(buffer.pop).to eq(:fresh)
    end
  end

  describe "concurrent push from multiple threads" do
    it "accepts all items without loss from 100 threads pushing 10 each" do
      big_buffer = described_class.new(capacity: 1024, max_bytes: 10_485_760)
      threads = 100.times.map do |t|
        Thread.new do
          10.times do |i|
            big_buffer.push("#{t}-#{i}", byte_size: 100)
          end
        end
      end
      threads.each(&:join)

      expect(big_buffer.size).to eq(1000)

      collected = []
      collected << big_buffer.pop until big_buffer.empty?
      expect(collected.uniq.length).to eq(1000)
    end
  end

  describe "#byte_size tracking" do
    it "tracks cumulative byte size of pushed items" do
      buffer.push(:a, byte_size: 100)
      buffer.push(:b, byte_size: 250)
      expect(buffer.byte_size).to eq(350)
    end

    it "decrements byte_size on pop" do
      buffer.push(:a, byte_size: 100)
      buffer.push(:b, byte_size: 250)
      buffer.pop
      expect(buffer.byte_size).to eq(250)
    end

    it "decrements byte_size on pop_batch" do
      buffer.push(:a, byte_size: 100)
      buffer.push(:b, byte_size: 200)
      buffer.push(:c, byte_size: 300)
      buffer.pop_batch(2)
      expect(buffer.byte_size).to eq(300)
    end

    it "uses default byte_size when none provided" do
      buffer.push(:a)
      expect(buffer.byte_size).to eq(OpenTrace::RingBuffer::DEFAULT_ITEM_BYTE_SIZE)
    end
  end

  describe "wrap-around behavior" do
    it "correctly wraps head and tail around the circular buffer" do
      # Fill and drain multiple times to exercise wrap-around
      3.times do |round|
        4.times { |i| buffer.push("r#{round}-#{i}", byte_size: 50) }
        items = buffer.pop_batch(4)
        expect(items).to eq(4.times.map { |i| "r#{round}-#{i}" })
        expect(buffer.empty?).to be true
      end
    end
  end

  describe "default constructor" do
    it "uses default capacity and max_bytes" do
      default_buf = described_class.new
      expect(default_buf.capacity).to eq(1024)
      expect(default_buf.max_bytes).to eq(10_485_760)
    end
  end
end
