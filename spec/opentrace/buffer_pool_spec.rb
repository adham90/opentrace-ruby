# frozen_string_literal: true

require "spec_helper"
require "opentrace/buffer_pool"

RSpec.describe OpenTrace::BufferPool do
  subject(:pool) { described_class.new(size: pool_size, max_buffer_bytes: 1_048_576, max_audit_events: 50) }

  let(:pool_size) { 4 }

  describe "#checkout" do
    it "returns a RequestBuffer" do
      buffer = pool.checkout
      expect(buffer).to be_a(OpenTrace::RequestBuffer)
      pool.checkin(buffer)
    end

    it "sets id on the buffer" do
      buffer = pool.checkout
      expect(buffer.id).to be_a(String)
      expect(buffer.id.length).to eq(26) # ULID is 26 chars
      pool.checkin(buffer)
    end

    it "sets started_at on the buffer" do
      buffer = pool.checkout
      expect(buffer.started_at).to be_a(Float)
      expect(buffer.started_at).to be > 0
      pool.checkin(buffer)
    end

    it "decrements available count" do
      expect(pool.stats[:available]).to eq(pool_size)

      buffer = pool.checkout
      expect(pool.stats[:available]).to eq(pool_size - 1)
      expect(pool.stats[:checked_out]).to eq(1)

      pool.checkin(buffer)
    end
  end

  describe "#checkin" do
    it "resets the buffer on checkin" do
      buffer = pool.checkout
      buffer.request_method = "GET"
      buffer.request_path = "/test"
      buffer.record_sql(raw_sql: "SELECT 1", duration_ms: 1.0)

      pool.checkin(buffer)

      # After checkin, the buffer should be reset
      expect(buffer.request_method).to be_nil
      expect(buffer.request_path).to be_nil
      expect(buffer.sql_captures).to be_empty
      expect(buffer.id).to be_nil
    end

    it "checkout reuses the same buffer (object_id)" do
      buffer = pool.checkout
      original_id = buffer.object_id

      pool.checkin(buffer)
      reused = pool.checkout

      expect(reused.object_id).to eq(original_id)
      pool.checkin(reused)
    end
  end

  describe "checkout from empty pool" do
    it "creates new buffer when pool is exhausted" do
      # Checkout all pre-allocated buffers
      buffers = pool_size.times.map { pool.checkout }
      expect(pool.stats[:available]).to eq(0)

      # Pool is empty — should still return a new buffer
      extra = pool.checkout
      expect(extra).to be_a(OpenTrace::RequestBuffer)
      expect(extra.id).to be_a(String)

      # Clean up
      pool.checkin(extra)
      buffers.each { |b| pool.checkin(b) }
    end

    it "discards excess buffers on checkin when pool is full" do
      # Checkout all, then check in all
      buffers = pool_size.times.map { pool.checkout }
      extra = pool.checkout # one more beyond pool size

      # Check all back in
      buffers.each { |b| pool.checkin(b) }
      pool.checkin(extra) # this one should be discarded

      # Pool should be at max, not over
      expect(pool.stats[:available]).to eq(pool_size)
    end
  end

  describe "concurrent checkout/checkin from multiple threads" do
    it "handles concurrent access safely" do
      concurrent_pool = described_class.new(size: 8)
      errors = []
      threads = []

      20.times do
        threads << Thread.new do
          10.times do
            buf = concurrent_pool.checkout
            # Simulate some work
            buf.request_method = "GET"
            buf.record_sql(raw_sql: "SELECT 1", duration_ms: 0.1)
            concurrent_pool.checkin(buf)
          end
        rescue => e
          errors << e
        end
      end

      threads.each(&:join)

      expect(errors).to be_empty

      stats = concurrent_pool.stats
      expect(stats[:checked_out]).to eq(0)
      expect(stats[:available]).to be <= stats[:pool_size]
    end
  end

  describe "#stats" do
    it "reports correctly" do
      stats = pool.stats
      expect(stats[:pool_size]).to eq(pool_size)
      expect(stats[:available]).to eq(pool_size)
      expect(stats[:checked_out]).to eq(0)

      b1 = pool.checkout
      b2 = pool.checkout

      stats = pool.stats
      expect(stats[:available]).to eq(pool_size - 2)
      expect(stats[:checked_out]).to eq(2)

      pool.checkin(b1)
      stats = pool.stats
      expect(stats[:available]).to eq(pool_size - 1)
      expect(stats[:checked_out]).to eq(1)

      pool.checkin(b2)
      stats = pool.stats
      expect(stats[:available]).to eq(pool_size)
      expect(stats[:checked_out]).to eq(0)
    end
  end
end
