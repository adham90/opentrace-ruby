# frozen_string_literal: true

require_relative "../spec_helper"
require "opentrace/pool_monitor"

RSpec.describe OpenTrace::PoolMonitor do
  before do
    configure_opentrace!
    stub_request(:post, "https://opentrace.test/api/logs")
      .to_return(status: 201, body: '{"count":1}')
  end

  # Stub ActiveRecord connection pool
  def stub_pool(stats)
    pool = double("ConnectionPool", stat: stats)
    base = double("ActiveRecord::Base", connection_pool: pool)
    stub_const("ActiveRecord::Base", base)
  end

  it "reports pool stats at configured interval" do
    stub_pool(size: 10, busy: 8, dead: 0, idle: 2, waiting: 0, checkout_timeout: 5.0)

    monitor = described_class.new(interval: 0.2)
    monitor.start
    sleep 0.5
    monitor.stop

    expect(
      a_request(:post, "https://opentrace.test/api/logs")
        .with { |req|
          body = parse_log_body(req)
          body["metadata"]["metric_type"] == "db_pool" &&
            body["metadata"]["pool_size"] == 10 &&
            body["metadata"]["connections_busy"] == 8 &&
            body["metadata"]["connections_idle"] == 2
        }
    ).to have_been_made.at_least_once
  end

  it "logs at WARN level when threads are waiting" do
    stub_pool(size: 10, busy: 10, dead: 0, idle: 0, waiting: 3, checkout_timeout: 5.0)

    monitor = described_class.new(interval: 0.2)
    monitor.start
    sleep 0.5
    monitor.stop

    expect(
      a_request(:post, "https://opentrace.test/api/logs")
        .with { |req|
          body = parse_log_body(req)
          body["level"] == "WARN" &&
            body["metadata"]["threads_waiting"] == 3
        }
    ).to have_been_made.at_least_once
  end

  it "logs at DEBUG level when pool is healthy" do
    stub_pool(size: 10, busy: 5, dead: 0, idle: 5, waiting: 0, checkout_timeout: 5.0)

    monitor = described_class.new(interval: 0.2)
    monitor.start
    sleep 0.5
    monitor.stop

    expect(
      a_request(:post, "https://opentrace.test/api/logs")
        .with { |req|
          body = parse_log_body(req)
          body["level"] == "DEBUG"
        }
    ).to have_been_made.at_least_once
  end

  it "does nothing when OpenTrace is disabled" do
    OpenTrace.disable!

    stub_pool(size: 10, busy: 10, dead: 0, idle: 0, waiting: 5, checkout_timeout: 5.0)

    monitor = described_class.new(interval: 0.2)
    monitor.start
    sleep 0.5
    monitor.stop

    # No logs should be sent (only the safety stub catches requests)
    expect(
      a_request(:post, "https://opentrace.test/api/logs")
    ).not_to have_been_made
  end

  it "stops cleanly" do
    stub_pool(size: 5, busy: 2, dead: 0, idle: 3, waiting: 0, checkout_timeout: 5.0)

    monitor = described_class.new(interval: 0.2)
    monitor.start
    monitor.stop

    # Should not raise or hang
    expect(true).to be true
  end

  it "swallows errors from pool.stat" do
    pool = double("ConnectionPool")
    allow(pool).to receive(:stat).and_raise(RuntimeError, "pool error")
    base = double("ActiveRecord::Base", connection_pool: pool)
    stub_const("ActiveRecord::Base", base)

    expect {
      monitor = described_class.new(interval: 0.2)
      monitor.start
      sleep 0.5
      monitor.stop
    }.not_to raise_error
  end
end
