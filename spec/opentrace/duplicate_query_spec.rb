# frozen_string_literal: true

RSpec.describe "Duplicate query detection" do
  describe "RequestCollector fingerprint tracking" do
    let(:collector) { OpenTrace::RequestCollector.new(max_timeline: 0) }

    it "tracks duplicate queries by fingerprint" do
      5.times { collector.record_sql(name: "User Load", duration_ms: 1.0, fingerprint: "abc123") }
      3.times { collector.record_sql(name: "Post Load", duration_ms: 0.5, fingerprint: "def456") }
      collector.record_sql(name: "Setting Load", duration_ms: 0.2, fingerprint: "ghi789")

      summary = collector.summary
      expect(summary[:duplicate_queries]).to eq(2) # abc123 and def456
      expect(summary[:worst_duplicate_count]).to eq(5)
    end

    it "reports top duplicates sorted by count" do
      10.times { collector.record_sql(name: "User Load", duration_ms: 1.0, fingerprint: "most") }
      5.times { collector.record_sql(name: "Post Load", duration_ms: 0.5, fingerprint: "middle") }
      2.times { collector.record_sql(name: "Tag Load", duration_ms: 0.3, fingerprint: "least") }

      summary = collector.summary
      top = summary[:top_duplicates]
      expect(top.length).to eq(3)
      expect(top[0][:fingerprint]).to eq("most")
      expect(top[0][:count]).to eq(10)
      expect(top[1][:fingerprint]).to eq("middle")
      expect(top[2][:fingerprint]).to eq("least")
    end

    it "limits to top 3 duplicates" do
      5.times { |i| 3.times { collector.record_sql(name: "Q#{i}", duration_ms: 1.0, fingerprint: "fp#{i}") } }

      summary = collector.summary
      expect(summary[:top_duplicates].length).to eq(3)
    end

    it "sets n_plus_one_warning when worst duplicate > 5" do
      10.times { collector.record_sql(name: "User Load", duration_ms: 1.0, fingerprint: "abc") }

      summary = collector.summary
      expect(summary[:n_plus_one_warning]).to be true
    end

    it "does not set n_plus_one_warning for moderate duplicates" do
      3.times { collector.record_sql(name: "User Load", duration_ms: 1.0, fingerprint: "abc") }
      # sql_count = 3, which is <= 20, and worst_duplicate = 3 which is <= 5
      summary = collector.summary
      # n_plus_one could be nil (not set for low counts)
      expect(summary[:n_plus_one_warning]).to be_nil
    end

    it "does not report duplicates when all queries are unique" do
      3.times { |i| collector.record_sql(name: "Q#{i}", duration_ms: 1.0, fingerprint: "fp#{i}") }

      summary = collector.summary
      expect(summary).not_to have_key(:duplicate_queries)
      expect(summary).not_to have_key(:top_duplicates)
    end

    it "caps fingerprint tracking at 100 unique fingerprints" do
      110.times { |i| collector.record_sql(name: "Q", duration_ms: 1.0, fingerprint: "fp#{i}") }
      # Should track first 100, skip the rest
      expect(collector.instance_variable_get(:@sql_fingerprints).size).to eq(100)
    end

    it "handles nil fingerprint gracefully" do
      collector.record_sql(name: "Q", duration_ms: 1.0, fingerprint: nil)
      expect(collector.instance_variable_get(:@sql_fingerprints)).to be_empty
    end
  end
end
