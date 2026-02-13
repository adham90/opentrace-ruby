# frozen_string_literal: true

RSpec.describe OpenTrace::Span do
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

  after do
    Fiber[:opentrace_trace_id] = nil
    Fiber[:opentrace_span_id] = nil
    OpenTrace.shutdown(timeout: 1)
  end

  describe "#initialize" do
    it "generates a unique span_id" do
      span = described_class.new(
        operation: "test.op",
        resource: nil,
        parent_span_id: nil,
        trace_id: "abc123"
      )
      expect(span.span_id).to be_a(String)
      expect(span.span_id.length).to eq(16)
    end

    it "stores operation and resource" do
      span = described_class.new(
        operation: "stripe.charge",
        resource: "Order#42",
        parent_span_id: nil,
        trace_id: "abc123"
      )
      expect(span.operation).to eq("stripe.charge")
      expect(span.resource).to eq("Order#42")
    end
  end

  describe "#set_tag" do
    it "stores tags for inclusion in metadata" do
      span = described_class.new(
        operation: "test",
        resource: nil,
        parent_span_id: nil,
        trace_id: "abc123"
      )
      span.set_tag(:amount, 2000)
      span.set_tag(:currency, "usd")

      allow(OpenTrace).to receive(:log) do |level, msg, meta|
        expect(meta[:amount]).to eq(2000)
        expect(meta[:currency]).to eq("usd")
      end
      span.finish
    end
  end

  describe "#finish" do
    it "logs the span with duration" do
      span = described_class.new(
        operation: "test.op",
        resource: nil,
        parent_span_id: nil,
        trace_id: "abc123"
      )
      sleep 0.01

      expect(OpenTrace).to receive(:log) do |level, msg, meta|
        expect(level).to eq("INFO")
        expect(msg).to eq("span:test.op")
        expect(meta[:span_operation]).to eq("test.op")
        expect(meta[:span_duration_ms]).to be > 0
      end

      span.finish
    end

    it "logs ERROR level when error is provided" do
      span = described_class.new(
        operation: "test.op",
        resource: nil,
        parent_span_id: nil,
        trace_id: "abc123"
      )

      error = RuntimeError.new("test error")
      expect(OpenTrace).to receive(:log) do |level, msg, meta|
        expect(level).to eq("ERROR")
        expect(meta[:exception_class]).to eq("RuntimeError")
        expect(meta[:exception_message]).to eq("test error")
      end

      span.finish(error: error)
    end

    it "includes resource in metadata when set" do
      span = described_class.new(
        operation: "pdf.generate",
        resource: "Invoice",
        parent_span_id: nil,
        trace_id: "abc123"
      )

      expect(OpenTrace).to receive(:log) do |level, msg, meta|
        expect(meta[:span_resource]).to eq("Invoice")
      end

      span.finish
    end

    it "is idempotent (only finishes once)" do
      span = described_class.new(
        operation: "test.op",
        resource: nil,
        parent_span_id: nil,
        trace_id: "abc123"
      )

      expect(OpenTrace).to receive(:log).once
      span.finish
      span.finish # should be a no-op
    end
  end
end

RSpec.describe OpenTrace::NilSpan do
  describe "INSTANCE" do
    it "is frozen" do
      expect(OpenTrace::NilSpan::INSTANCE).to be_frozen
    end

    it "set_tag returns nil" do
      expect(OpenTrace::NilSpan::INSTANCE.set_tag(:key, :value)).to be_nil
    end

    it "finish returns nil" do
      expect(OpenTrace::NilSpan::INSTANCE.finish).to be_nil
    end
  end
end
