# frozen_string_literal: true

require_relative "../spec_helper"
require "opentrace/request_collector"

RSpec.describe "Memory tracking" do
  before do
    configure_opentrace!
  end

  describe "RequestCollector memory fields" do
    it "includes memory delta in summary when both before and after are set" do
      collector = OpenTrace::RequestCollector.new
      collector.memory_before = 256.0
      collector.memory_after = 340.2

      summary = collector.summary
      expect(summary[:memory_before_mb]).to eq(256.0)
      expect(summary[:memory_after_mb]).to eq(340.2)
      expect(summary[:memory_delta_mb]).to eq(84.2)
    end

    it "omits memory fields when tracking is not enabled" do
      collector = OpenTrace::RequestCollector.new
      # No memory_before/after set

      summary = collector.summary
      expect(summary).not_to have_key(:memory_before_mb)
      expect(summary).not_to have_key(:memory_after_mb)
      expect(summary).not_to have_key(:memory_delta_mb)
    end

    it "handles negative memory delta (GC freed memory)" do
      collector = OpenTrace::RequestCollector.new
      collector.memory_before = 300.0
      collector.memory_after = 280.5

      summary = collector.summary
      expect(summary[:memory_delta_mb]).to eq(-19.5)
    end
  end

  describe "Middleware memory snapshots" do
    let(:app) { ->(env) { [200, {}, ["OK"]] } }
    let(:middleware) { OpenTrace::Middleware.new(app) }

    it "captures memory when memory_tracking is enabled" do
      OpenTrace.config.memory_tracking = true
      OpenTrace.config.request_summary = true

      env = { "action_dispatch.request_id" => "req-mem-test" }
      middleware.call(env)

      # After the request, collector has been cleaned up by ensure block
      # But we can verify no crash occurred
      expect(Fiber[:opentrace_collector]).to be_nil
    end

    it "does not create collector when memory_tracking is disabled and no other features need it" do
      OpenTrace.config.memory_tracking = false
      OpenTrace.config.request_summary = true

      collector_before_cleanup = nil
      tracking_app = lambda do |env|
        collector_before_cleanup = Fiber[:opentrace_collector]
        [200, {}, ["OK"]]
      end

      mw = OpenTrace::Middleware.new(tracking_app)
      mw.call("action_dispatch.request_id" => "req-mem-off")

      # No collector when no features (view/cache/http/timeline/memory) need it
      expect(collector_before_cleanup).to be_nil
    end

    it "captures memory snapshots during request lifecycle" do
      OpenTrace.config.memory_tracking = true
      OpenTrace.config.request_summary = true

      collector_snapshot = nil
      tracking_app = lambda do |env|
        collector_snapshot = Fiber[:opentrace_collector]
        [200, {}, ["OK"]]
      end

      mw = OpenTrace::Middleware.new(tracking_app)
      mw.call("action_dispatch.request_id" => "req-mem-snap")

      # Before cleanup, the collector should have memory_before set
      expect(collector_snapshot.memory_before).to be_a(Numeric)
      expect(collector_snapshot.memory_before).to be > 0
      # After request, memory_after is set in the ensure block
      expect(collector_snapshot.memory_after).to be_a(Numeric)
    end
  end
end
