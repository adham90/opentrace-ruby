# frozen_string_literal: true

require_relative "../../lib/opentrace/runtime_monitor"

RSpec.describe OpenTrace::RuntimeMonitor do
  before do
    OpenTrace.reset!
    OpenTrace.configure do |c|
      c.endpoint = "https://opentrace.test"
      c.api_key = "test-key"
      c.service = "test-app"
      c.flush_interval = 0.2
    end
    stub_request(:any, /opentrace\.test/).to_return(status: 200, body: "{}")
  end

  after { OpenTrace.shutdown(timeout: 1) }

  it "initializes with default interval" do
    monitor = described_class.new
    expect(monitor.running?).to be false
  end

  it "initializes with custom interval" do
    monitor = described_class.new(interval: 10)
    expect(monitor.running?).to be false
  end

  it "starts and stops" do
    monitor = described_class.new(interval: 60)
    monitor.start
    expect(monitor.running?).to be true
    monitor.stop
    expect(monitor.running?).to be false
  end

  it "does not start twice" do
    monitor = described_class.new(interval: 60)
    monitor.start
    monitor.start # should be a no-op
    expect(monitor.running?).to be true
    monitor.stop
  end

  describe "collect_and_send" do
    it "sends runtime metrics event" do
      enqueued = []
      allow_any_instance_of(OpenTrace::Client).to receive(:enqueue) { |_, p| enqueued << p }

      monitor = described_class.new(interval: 0.1)
      monitor.start
      sleep 0.3
      monitor.stop

      # Should have enqueued at least one event (flat SDK format)
      events = enqueued.select { |e| e.is_a?(Hash) && e[:event_type] == "runtime.metrics" }
      expect(events).not_to be_empty

      context = events.first.dig(:body, :context)
      expect(context).to have_key(:gc_count)
      expect(context).to have_key(:gc_major_count)
      expect(context).to have_key(:gc_minor_count)
      expect(context).to have_key(:gc_heap_live_slots)
      expect(context).to have_key(:thread_count)
      expect(context).to have_key(:process_pid)
      expect(context[:process_pid]).to eq(Process.pid)
    end
  end

  describe "config" do
    it "defaults runtime_metrics to false" do
      config = OpenTrace::Config.new
      expect(config.runtime_metrics).to be false
    end

    it "defaults runtime_metrics_interval to 30" do
      config = OpenTrace::Config.new
      expect(config.runtime_metrics_interval).to eq(30)
    end
  end
end
