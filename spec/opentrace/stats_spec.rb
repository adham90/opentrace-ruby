# frozen_string_literal: true

RSpec.describe OpenTrace::Stats do
  subject(:stats) { described_class.new }

  describe "#initialize" do
    it "starts all counters at zero" do
      OpenTrace::Stats::COUNTERS.each do |counter|
        expect(stats.get(counter)).to eq(0)
      end
    end

    it "records a start time" do
      h = stats.to_h
      expect(h[:uptime_seconds]).to be >= 0
    end
  end

  describe "#increment" do
    it "increments a counter by 1 by default" do
      stats.increment(:enqueued)
      expect(stats.get(:enqueued)).to eq(1)
    end

    it "increments a counter by a custom amount" do
      stats.increment(:bytes_sent, 1024)
      expect(stats.get(:bytes_sent)).to eq(1024)
    end

    it "accumulates multiple increments" do
      3.times { stats.increment(:delivered) }
      expect(stats.get(:delivered)).to eq(3)
    end
  end

  describe "#get" do
    it "returns the current value of a counter" do
      stats.increment(:retries, 5)
      expect(stats.get(:retries)).to eq(5)
    end

    it "returns 0 for untouched counters" do
      expect(stats.get(:dropped_error)).to eq(0)
    end
  end

  describe "#to_h" do
    it "returns all counters as a hash" do
      stats.increment(:enqueued, 10)
      stats.increment(:delivered, 8)
      h = stats.to_h
      expect(h[:enqueued]).to eq(10)
      expect(h[:delivered]).to eq(8)
      expect(h[:dropped_queue_full]).to eq(0)
    end

    it "includes uptime_seconds" do
      h = stats.to_h
      expect(h).to have_key(:uptime_seconds)
      expect(h[:uptime_seconds]).to be_a(Integer)
    end

    it "returns a frozen snapshot (dup)" do
      h1 = stats.to_h
      stats.increment(:enqueued)
      h2 = stats.to_h
      expect(h1[:enqueued]).to eq(0)
      expect(h2[:enqueued]).to eq(1)
    end
  end

  describe "#reset!" do
    it "resets all counters to zero" do
      stats.increment(:enqueued, 100)
      stats.increment(:delivered, 90)
      stats.increment(:bytes_sent, 50_000)
      stats.reset!

      OpenTrace::Stats::COUNTERS.each do |counter|
        expect(stats.get(counter)).to eq(0)
      end
    end

    it "resets the uptime" do
      sleep 0.1
      stats.reset!
      h = stats.to_h
      expect(h[:uptime_seconds]).to eq(0)
    end
  end

  describe "thread safety" do
    it "handles concurrent increments without data loss" do
      threads = 10.times.map do
        Thread.new do
          100.times { stats.increment(:enqueued) }
        end
      end
      threads.each(&:join)

      expect(stats.get(:enqueued)).to eq(1000)
    end
  end

  describe "COUNTERS" do
    it "includes all expected counter names" do
      expected = %i[
        enqueued delivered dropped_queue_full dropped_circuit_open
        dropped_auth_suspended dropped_error dropped_filtered retries rate_limited
        auth_failures payload_splits batches_sent bytes_sent
        sampled_out sql_filtered
      ]
      expect(OpenTrace::Stats::COUNTERS).to match_array(expected)
    end
  end
end
