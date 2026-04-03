# frozen_string_literal: true

require "spec_helper"
require "opentrace/memory_guard"

RSpec.describe OpenTrace::MemoryGuard do
  subject(:guard) { described_class.new(max_total_bytes: 1000, pressure_threshold: 0.8) }

  describe "#allocate / #release" do
    it "tracks allocated bytes" do
      guard.allocate(300)
      expect(guard.current_bytes).to eq(300)
    end

    it "allows allocation within limit" do
      expect(guard.allocate(500)).to be true
      expect(guard.allocate(400)).to be true
      expect(guard.current_bytes).to eq(900)
    end

    it "rejects allocation when limit would be exceeded" do
      guard.allocate(800)
      expect(guard.allocate(300)).to be false
      expect(guard.current_bytes).to eq(800) # unchanged
    end

    it "releases bytes correctly" do
      guard.allocate(500)
      guard.release(200)
      expect(guard.current_bytes).to eq(300)
    end

    it "never goes below zero on release" do
      guard.allocate(100)
      guard.release(500)
      expect(guard.current_bytes).to eq(0)
    end
  end

  describe "#exceeded?" do
    it "returns false when under limit" do
      guard.allocate(500)
      expect(guard.exceeded?).to be false
    end

    it "returns true when at limit" do
      guard.allocate(1000)
      expect(guard.exceeded?).to be true
    end
  end

  describe "#update_pressure / #under_pressure?" do
    it "is not under pressure initially" do
      expect(guard.under_pressure?).to be false
    end

    it "sets under_pressure when queue fill exceeds threshold" do
      guard.update_pressure(0.9)
      expect(guard.under_pressure?).to be true
    end

    it "clears under_pressure when queue fill drops" do
      guard.update_pressure(0.9)
      guard.update_pressure(0.5)
      expect(guard.under_pressure?).to be false
    end
  end

  describe "#effective_level" do
    it "returns configured level when no pressure" do
      expect(guard.effective_level(:full)).to eq(:full)
    end

    it "returns :minimal when memory exceeded" do
      guard.allocate(1000)
      expect(guard.effective_level(:full)).to eq(:minimal)
    end

    it "downgrades one level when under pressure" do
      guard.update_pressure(0.9)
      expect(guard.effective_level(:full)).to eq(:standard)
      expect(guard.effective_level(:standard)).to eq(:minimal)
      expect(guard.effective_level(:minimal)).to eq(:none)
    end

    it "does not downgrade :none further" do
      guard.update_pressure(0.9)
      expect(guard.effective_level(:none)).to eq(:none)
    end
  end

  describe "#reset!" do
    it "clears all state" do
      guard.allocate(500)
      guard.update_pressure(0.9)
      guard.reset!
      expect(guard.current_bytes).to eq(0)
      expect(guard.under_pressure?).to be false
    end
  end

  describe "#stats" do
    it "returns usage info" do
      guard.allocate(500)
      stats = guard.stats
      expect(stats[:current_bytes]).to eq(500)
      expect(stats[:max_total_bytes]).to eq(1000)
      expect(stats[:usage_pct]).to eq(50.0)
      expect(stats[:under_pressure]).to be false
    end
  end

  describe "thread safety" do
    it "handles concurrent allocations and releases" do
      threads = 20.times.map do
        Thread.new do
          50.times do
            guard.allocate(10)
            guard.release(10)
          end
        end
      end
      threads.each(&:join)
      expect(guard.current_bytes).to eq(0)
    end
  end
end
