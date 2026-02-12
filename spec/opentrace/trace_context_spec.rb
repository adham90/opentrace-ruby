# frozen_string_literal: true

RSpec.describe OpenTrace::TraceContext do
  describe ".parse_traceparent" do
    it "parses a valid traceparent header" do
      result = described_class.parse_traceparent("00-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7-01")

      expect(result).to eq({
        version: "00",
        trace_id: "4bf92f3577b34da6a3ce929d0e0e4736",
        parent_id: "00f067aa0ba902b7",
        flags: "01"
      })
    end

    it "parses unsampled traceparent" do
      result = described_class.parse_traceparent("00-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7-00")
      expect(result[:flags]).to eq("00")
    end

    it "handles whitespace" do
      result = described_class.parse_traceparent("  00-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7-01  ")
      expect(result).not_to be_nil
      expect(result[:trace_id]).to eq("4bf92f3577b34da6a3ce929d0e0e4736")
    end

    it "returns nil for nil input" do
      expect(described_class.parse_traceparent(nil)).to be_nil
    end

    it "returns nil for empty string" do
      expect(described_class.parse_traceparent("")).to be_nil
    end

    it "returns nil for invalid format" do
      expect(described_class.parse_traceparent("not-a-traceparent")).to be_nil
    end

    it "returns nil for wrong number of parts" do
      expect(described_class.parse_traceparent("00-4bf92f3577b34da6a3ce929d0e0e4736-01")).to be_nil
    end

    it "returns nil for non-hex characters in trace_id" do
      expect(described_class.parse_traceparent("00-ZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZ-00f067aa0ba902b7-01")).to be_nil
    end
  end

  describe ".build_traceparent" do
    it "builds a valid sampled traceparent" do
      result = described_class.build_traceparent(
        trace_id: "4bf92f3577b34da6a3ce929d0e0e4736",
        span_id: "00f067aa0ba902b7"
      )
      expect(result).to eq("00-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7-01")
    end

    it "builds an unsampled traceparent" do
      result = described_class.build_traceparent(
        trace_id: "4bf92f3577b34da6a3ce929d0e0e4736",
        span_id: "00f067aa0ba902b7",
        sampled: false
      )
      expect(result).to eq("00-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7-00")
    end

    it "normalizes UUID trace_id to 32 hex chars" do
      result = described_class.build_traceparent(
        trace_id: "550e8400-e29b-41d4-a716-446655440000",
        span_id: "00f067aa0ba902b7"
      )
      expect(result).to start_with("00-550e8400e29b41d4a716446655440000-")
    end
  end

  describe ".normalize_trace_id" do
    it "passes through 32-char hex IDs unchanged" do
      expect(described_class.normalize_trace_id("4bf92f3577b34da6a3ce929d0e0e4736")).to eq("4bf92f3577b34da6a3ce929d0e0e4736")
    end

    it "strips hyphens from UUIDs" do
      expect(described_class.normalize_trace_id("550e8400-e29b-41d4-a716-446655440000")).to eq("550e8400e29b41d4a716446655440000")
    end

    it "pads short IDs with zeros" do
      expect(described_class.normalize_trace_id("abc123")).to eq("abc12300000000000000000000000000")
    end

    it "truncates long IDs to 32 chars" do
      long_id = "a" * 40
      expect(described_class.normalize_trace_id(long_id)).to eq("a" * 32)
    end

    it "lowercases hex chars" do
      expect(described_class.normalize_trace_id("4BF92F3577B34DA6A3CE929D0E0E4736")).to eq("4bf92f3577b34da6a3ce929d0e0e4736")
    end

    it "returns nil for empty string" do
      expect(described_class.normalize_trace_id("")).to be_nil
    end

    it "returns nil for nil" do
      expect(described_class.normalize_trace_id(nil)).to be_nil
    end
  end

  describe ".generate_span_id" do
    it "generates a 16-char hex string" do
      span_id = described_class.generate_span_id
      expect(span_id).to match(/\A\h{16}\z/)
    end

    it "generates unique IDs" do
      ids = 10.times.map { described_class.generate_span_id }
      expect(ids.uniq.size).to eq(10)
    end
  end

  describe ".generate_trace_id" do
    it "generates a 32-char hex string" do
      trace_id = described_class.generate_trace_id
      expect(trace_id).to match(/\A\h{32}\z/)
    end
  end
end
