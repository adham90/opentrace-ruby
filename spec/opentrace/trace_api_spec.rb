# frozen_string_literal: true

RSpec.describe "OpenTrace.trace API" do
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

  describe "OpenTrace.trace" do
    it "returns the block result" do
      result = OpenTrace.trace("test.op") { 42 }
      expect(result).to eq(42)
    end

    it "yields a Span object" do
      OpenTrace.trace("test.op") do |span|
        expect(span).to be_a(OpenTrace::Span)
      end
    end

    it "sets span_id during block execution" do
      Fiber[:opentrace_trace_id] = "trace-123"
      original_span_id = Fiber[:opentrace_span_id]

      OpenTrace.trace("test.op") do |span|
        expect(Fiber[:opentrace_span_id]).to eq(span.span_id)
        expect(Fiber[:opentrace_span_id]).not_to eq(original_span_id)
      end

      # Span ID restored after block
      expect(Fiber[:opentrace_span_id]).to eq(original_span_id)
    end

    it "supports nested spans" do
      Fiber[:opentrace_trace_id] = "trace-123"
      outer_span = nil
      inner_span = nil

      OpenTrace.trace("outer") do |os|
        outer_span = os
        OpenTrace.trace("inner") do |is|
          inner_span = is
          expect(Fiber[:opentrace_span_id]).to eq(inner_span.span_id)
        end
        expect(Fiber[:opentrace_span_id]).to eq(outer_span.span_id)
      end
    end

    it "re-raises exceptions from the block" do
      expect {
        OpenTrace.trace("failing.op") do
          raise RuntimeError, "test error"
        end
      }.to raise_error(RuntimeError, "test error")
    end

    it "records error when block raises" do
      expect(OpenTrace).to receive(:log).with("ERROR", "span:failing.op", hash_including(
        exception_class: "RuntimeError"
      ))

      begin
        OpenTrace.trace("failing.op") { raise RuntimeError, "test error" }
      rescue RuntimeError
        # expected
      end
    end

    it "yields NilSpan when disabled" do
      OpenTrace.disable!

      OpenTrace.trace("test.op") do |span|
        expect(span).to eq(OpenTrace::NilSpan::INSTANCE)
      end
    end

    it "merges tags from trace call and span.set_tag" do
      expect(OpenTrace).to receive(:log) do |level, msg, meta|
        expect(meta[:span_operation]).to eq("test.op")
        expect(meta[:from_trace]).to eq(true)
        expect(meta[:from_set_tag]).to eq(true)
      end

      OpenTrace.trace("test.op", tags: { from_trace: true }) do |span|
        span.set_tag(:from_set_tag, true)
      end
    end
  end
end
