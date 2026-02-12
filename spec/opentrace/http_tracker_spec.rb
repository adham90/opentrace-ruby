# frozen_string_literal: true

require_relative "../spec_helper"
require "opentrace/request_collector"
require "opentrace/http_tracker"

RSpec.describe OpenTrace::HttpTracker do
  before do
    configure_opentrace!
    stub_request(:any, /example\.com/)
      .to_return(status: 200, body: "OK")
    stub_request(:post, "https://opentrace.test/api/logs")
      .to_return(status: 201, body: '{"count":1}')
  end

  # Apply the prepend only once
  before(:all) do
    Net::HTTP.prepend(OpenTrace::HttpTracker) unless Net::HTTP.ancestors.include?(OpenTrace::HttpTracker)
  end

  it "records HTTP calls in the RequestCollector" do
    collector = OpenTrace::RequestCollector.new
    Fiber[:opentrace_collector] = collector

    uri = URI("https://example.com/api/data")
    Net::HTTP.get(uri)

    expect(collector.http_count).to eq(1)
    expect(collector.http_total_ms).to be > 0

    summary = collector.summary
    expect(summary[:http_external_count]).to eq(1)
    expect(summary[:http_slowest_host]).to eq("example.com")
  ensure
    Fiber[:opentrace_collector] = nil
  end

  it "includes HTTP calls in the timeline" do
    collector = OpenTrace::RequestCollector.new
    Fiber[:opentrace_collector] = collector

    uri = URI("https://example.com/api/data")
    Net::HTTP.get(uri)

    timeline = collector.summary[:timeline]
    expect(timeline.size).to eq(1)
    expect(timeline.first[:t]).to eq(:http)
    expect(timeline.first[:n]).to include("example.com")
    expect(timeline.first[:s]).to eq(200)
  ensure
    Fiber[:opentrace_collector] = nil
  end

  it "does nothing when no collector is present" do
    Fiber[:opentrace_collector] = nil

    # Should not raise
    uri = URI("https://example.com/api/data")
    expect { Net::HTTP.get(uri) }.not_to raise_error
  end

  it "does not track OpenTrace dispatch calls (recursion guard)" do
    collector = OpenTrace::RequestCollector.new
    Fiber[:opentrace_collector] = collector
    Fiber[:opentrace_http_tracking_disabled] = true

    uri = URI("https://example.com/api/data")
    Net::HTTP.get(uri)

    expect(collector.http_count).to eq(0)
  ensure
    Fiber[:opentrace_collector] = nil
    Fiber[:opentrace_http_tracking_disabled] = nil
  end

  it "does not track when OpenTrace is disabled" do
    OpenTrace.disable!
    collector = OpenTrace::RequestCollector.new
    Fiber[:opentrace_collector] = collector

    uri = URI("https://example.com/api/data")
    Net::HTTP.get(uri)

    expect(collector.http_count).to eq(0)
  ensure
    Fiber[:opentrace_collector] = nil
  end

  it "records failed HTTP calls and re-raises" do
    stub_request(:get, "https://timeout.example.com/slow")
      .to_timeout

    collector = OpenTrace::RequestCollector.new
    Fiber[:opentrace_collector] = collector

    expect {
      uri = URI("https://timeout.example.com/slow")
      Net::HTTP.get(uri)
    }.to raise_error(Net::OpenTimeout)

    expect(collector.http_count).to eq(1)
    timeline = collector.summary[:timeline]
    expect(timeline.first[:s]).to eq(0)
    expect(timeline.first[:err]).to be_a(String)
  ensure
    Fiber[:opentrace_collector] = nil
  end
end
