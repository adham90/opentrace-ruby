# frozen_string_literal: true

RSpec.describe OpenTrace::CircuitBreaker do
  subject(:breaker) do
    described_class.new(failure_threshold: 3, recovery_timeout: 1.0)
  end

  describe "initial state" do
    it "starts in closed state" do
      expect(breaker.state).to eq(:closed)
    end

    it "allows requests when closed" do
      expect(breaker.allow_request?).to be true
    end
  end

  describe "#record_failure" do
    it "stays closed below threshold" do
      2.times { breaker.record_failure }
      expect(breaker.state).to eq(:closed)
      expect(breaker.allow_request?).to be true
    end

    it "opens after reaching failure threshold" do
      3.times { breaker.record_failure }
      expect(breaker.state).to eq(:open)
      expect(breaker.allow_request?).to be false
    end
  end

  describe "#record_success" do
    it "resets failure count and returns to closed" do
      2.times { breaker.record_failure }
      breaker.record_success
      # Should be closed again, needing 3 fresh failures to open
      2.times { breaker.record_failure }
      expect(breaker.state).to eq(:closed)
    end

    it "transitions from half_open to closed" do
      # Open the circuit
      3.times { breaker.record_failure }
      expect(breaker.state).to eq(:open)

      # Wait for recovery timeout, then allow_request? transitions to half_open
      sleep(1.1)
      expect(breaker.allow_request?).to be true
      expect(breaker.state).to eq(:half_open)

      # Success closes the circuit
      breaker.record_success
      expect(breaker.state).to eq(:closed)
    end
  end

  describe "half_open state" do
    before do
      3.times { breaker.record_failure }
      sleep(1.1) # wait past recovery_timeout
    end

    it "allows one probe request after recovery timeout" do
      expect(breaker.allow_request?).to be true
      expect(breaker.state).to eq(:half_open)
    end

    it "blocks additional requests while probing" do
      breaker.allow_request? # first call transitions to half_open
      expect(breaker.allow_request?).to be false
    end

    it "reopens on failure during half_open" do
      breaker.allow_request? # transition to half_open
      breaker.record_failure
      expect(breaker.state).to eq(:open)
      expect(breaker.allow_request?).to be false
    end
  end

  describe "open state" do
    before do
      3.times { breaker.record_failure }
    end

    it "blocks all requests" do
      expect(breaker.allow_request?).to be false
    end

    it "remains open before recovery timeout" do
      sleep(0.3)
      expect(breaker.allow_request?).to be false
      expect(breaker.state).to eq(:open)
    end
  end

  describe "#reset!" do
    it "returns to closed state from open" do
      3.times { breaker.record_failure }
      expect(breaker.state).to eq(:open)

      breaker.reset!
      expect(breaker.state).to eq(:closed)
      expect(breaker.allow_request?).to be true
    end
  end

  describe "full recovery cycle" do
    it "recovers from open through half_open to closed" do
      # Open the circuit
      3.times { breaker.record_failure }
      expect(breaker.state).to eq(:open)
      expect(breaker.allow_request?).to be false

      # Wait for recovery timeout
      sleep(1.1)

      # First request transitions to half_open and is allowed (probe)
      expect(breaker.allow_request?).to be true
      expect(breaker.state).to eq(:half_open)

      # Probe succeeds — circuit closes
      breaker.record_success
      expect(breaker.state).to eq(:closed)

      # Normal operation resumes
      expect(breaker.allow_request?).to be true
    end

    it "re-opens on failure during half_open and can recover again" do
      # Open, wait, transition to half_open
      3.times { breaker.record_failure }
      sleep(1.1)
      breaker.allow_request? # probe allowed
      expect(breaker.state).to eq(:half_open)

      # Probe fails — back to open
      breaker.record_failure
      expect(breaker.state).to eq(:open)

      # Wait again, try another probe
      sleep(1.1)
      expect(breaker.allow_request?).to be true
      expect(breaker.state).to eq(:half_open)

      # This time it succeeds
      breaker.record_success
      expect(breaker.state).to eq(:closed)
    end
  end

  describe "thread safety" do
    it "handles concurrent access without errors" do
      threads = 20.times.map do
        Thread.new do
          50.times do
            breaker.allow_request?
            breaker.record_failure
            breaker.record_success
          end
        end
      end

      expect { threads.each(&:join) }.not_to raise_error
    end
  end
end
