# frozen_string_literal: true

require_relative "../spec_helper"
require "opentrace/request_collector"

RSpec.describe OpenTrace::RequestCollector do
  subject(:collector) { described_class.new }

  describe "#record_sql" do
    it "accumulates SQL count and total time" do
      collector.record_sql(name: "User Load", duration_ms: 1.5)
      collector.record_sql(name: "Order Load", duration_ms: 3.2)

      expect(collector.sql_count).to eq(2)
      expect(collector.sql_total_ms).to be_within(0.01).of(4.7)
    end

    it "tracks the slowest SQL query" do
      collector.record_sql(name: "Fast Query", duration_ms: 1.0)
      collector.record_sql(name: "Slow Query", duration_ms: 50.0)
      collector.record_sql(name: "Medium Query", duration_ms: 10.0)

      summary = collector.summary
      expect(summary[:sql_slowest_ms]).to eq(50.0)
      expect(summary[:sql_slowest_name]).to eq("Slow Query")
    end

    it "adds entries to the timeline" do
      collector.record_sql(name: "User Load", duration_ms: 2.0)

      timeline = collector.summary[:timeline]
      expect(timeline.size).to eq(1)
      expect(timeline.first[:t]).to eq(:sql)
      expect(timeline.first[:n]).to eq("User Load")
      expect(timeline.first[:ms]).to eq(2.0)
    end
  end

  describe "#record_view" do
    it "accumulates view count and total time" do
      collector.record_view(template: "orders/show.html.erb", duration_ms: 10.0)
      collector.record_view(template: "orders/_item.html.erb", duration_ms: 2.0)

      expect(collector.view_count).to eq(2)
      expect(collector.view_total_ms).to be_within(0.01).of(12.0)
    end

    it "tracks the slowest template" do
      collector.record_view(template: "fast.html.erb", duration_ms: 1.0)
      collector.record_view(template: "slow.html.erb", duration_ms: 100.0)

      summary = collector.summary
      expect(summary[:view_slowest_ms]).to eq(100.0)
      expect(summary[:view_slowest_template]).to eq("slow.html.erb")
    end
  end

  describe "#record_cache" do
    it "counts cache reads and hits" do
      collector.record_cache(action: :read, hit: true, duration_ms: 0.1)
      collector.record_cache(action: :read, hit: false, duration_ms: 0.5)
      collector.record_cache(action: :read, hit: true, duration_ms: 0.1)

      expect(collector.cache_reads).to eq(3)
      expect(collector.cache_hits).to eq(2)
    end

    it "counts cache writes" do
      collector.record_cache(action: :write, duration_ms: 0.3)
      collector.record_cache(action: :write, duration_ms: 0.2)

      summary = collector.summary
      expect(summary[:cache_writes]).to eq(2)
    end

    it "computes cache hit ratio" do
      collector.record_cache(action: :read, hit: true, duration_ms: 0.1)
      collector.record_cache(action: :read, hit: false, duration_ms: 0.1)

      summary = collector.summary
      expect(summary[:cache_hit_ratio]).to eq(0.5)
    end

    it "omits cache_hit_ratio when no reads" do
      collector.record_cache(action: :write, duration_ms: 0.3)

      summary = collector.summary
      expect(summary).not_to have_key(:cache_hit_ratio)
    end
  end

  describe "#summary" do
    it "sets n_plus_one_warning when sql_count > 20" do
      25.times { |i| collector.record_sql(name: "Query #{i}", duration_ms: 1.0) }

      summary = collector.summary
      expect(summary[:n_plus_one_warning]).to be true
    end

    it "omits n_plus_one_warning when sql_count <= 20" do
      5.times { |i| collector.record_sql(name: "Query #{i}", duration_ms: 1.0) }

      summary = collector.summary
      expect(summary).not_to have_key(:n_plus_one_warning)
    end

    it "omits nil values via compact" do
      summary = collector.summary
      expect(summary).not_to have_key(:sql_slowest_name)
      expect(summary).not_to have_key(:view_slowest_template)
      expect(summary).not_to have_key(:timeline)
    end

    it "includes all accumulated data" do
      collector.record_sql(name: "Load", duration_ms: 5.0)
      collector.record_view(template: "show.html.erb", duration_ms: 10.0)
      collector.record_cache(action: :read, hit: true, duration_ms: 0.1)

      summary = collector.summary
      expect(summary[:sql_query_count]).to eq(1)
      expect(summary[:view_render_count]).to eq(1)
      expect(summary[:cache_reads]).to eq(1)
      expect(summary[:timeline].size).to eq(3)
    end
  end

  describe "timeline capping" do
    it "caps timeline at max_timeline entries" do
      small_collector = described_class.new(max_timeline: 5)

      10.times { |i| small_collector.record_sql(name: "Q#{i}", duration_ms: 1.0) }

      timeline = small_collector.summary[:timeline]
      expect(timeline.size).to eq(5)
      # Keeps first 5
      expect(timeline.first[:n]).to eq("Q0")
      expect(timeline.last[:n]).to eq("Q4")
    end

    it "still counts all events even when timeline is capped" do
      small_collector = described_class.new(max_timeline: 3)

      10.times { |i| small_collector.record_sql(name: "Q#{i}", duration_ms: 1.0) }

      expect(small_collector.sql_count).to eq(10)
      expect(small_collector.summary[:timeline].size).to eq(3)
    end
  end

  describe "timeline offset" do
    it "records monotonic offset_ms values" do
      collector.record_sql(name: "First", duration_ms: 1.0)
      sleep 0.01
      collector.record_sql(name: "Second", duration_ms: 1.0)

      timeline = collector.summary[:timeline]
      expect(timeline[1][:at]).to be > timeline[0][:at]
    end
  end
end
