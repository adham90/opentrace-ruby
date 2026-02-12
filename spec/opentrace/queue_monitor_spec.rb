# frozen_string_literal: true

require_relative "../spec_helper"
require "opentrace/queue_monitor"

RSpec.describe OpenTrace::QueueMonitor do
  before do
    configure_opentrace!
    stub_request(:post, "https://opentrace.test/api/logs")
      .to_return(status: 201, body: '{"count":1}')
  end

  it "detects Sidekiq and reports queue stats" do
    # Stub Sidekiq
    queue1 = double("Queue", name: "default", size: 12, latency: 1.2)
    queue2 = double("Queue", name: "mailers", size: 847, latency: 62.0)
    sidekiq_queue_class = double("Sidekiq::Queue", all: [queue1, queue2])
    stub_const("Sidekiq::Queue", sidekiq_queue_class)

    monitor = described_class.new(interval: 0.2)
    monitor.start
    sleep 0.5
    monitor.stop

    expect(
      a_request(:post, "https://opentrace.test/api/logs")
        .with { |req|
          body = parse_log_body(req)
          body["metadata"]["metric_type"] == "queue_depth" &&
            body["metadata"]["adapter"] == "sidekiq" &&
            body["metadata"]["total_enqueued"] == 859 &&
            body["metadata"]["queues"]["default"]["size"] == 12 &&
            body["metadata"]["queues"]["mailers"]["size"] == 847
        }
    ).to have_been_made.at_least_once
  end

  it "escalates to WARN when total > 1000" do
    queue1 = double("Queue", name: "default", size: 1500, latency: 30.0)
    sidekiq_queue_class = double("Sidekiq::Queue", all: [queue1])
    stub_const("Sidekiq::Queue", sidekiq_queue_class)

    monitor = described_class.new(interval: 0.2)
    monitor.start
    sleep 0.5
    monitor.stop

    expect(
      a_request(:post, "https://opentrace.test/api/logs")
        .with { |req|
          body = parse_log_body(req)
          body["level"] == "WARN"
        }
    ).to have_been_made.at_least_once
  end

  it "does nothing when no adapter is detected" do
    # No Sidekiq, GoodJob, or SolidQueue defined
    monitor = described_class.new(interval: 0.2)
    monitor.start
    sleep 0.5
    monitor.stop

    expect(
      a_request(:post, "https://opentrace.test/api/logs")
        .with { |req|
          body = parse_log_body(req)
          body["metadata"]["metric_type"] == "queue_depth"
        }
    ).not_to have_been_made
  end

  it "swallows errors from queue queries" do
    sidekiq_queue_class = double("Sidekiq::Queue")
    allow(sidekiq_queue_class).to receive(:all).and_raise(RuntimeError, "Redis down")
    stub_const("Sidekiq::Queue", sidekiq_queue_class)

    expect {
      monitor = described_class.new(interval: 0.2)
      monitor.start
      sleep 0.5
      monitor.stop
    }.not_to raise_error
  end

  it "stops cleanly" do
    monitor = described_class.new(interval: 0.2)
    monitor.start
    monitor.stop
    expect(true).to be true
  end
end
