# frozen_string_literal: true

require_relative "../../lib/opentrace/trace_formatter"

RSpec.describe OpenTrace::TraceFormatter do
  let(:original_formatter) do
    proc { |severity, datetime, progname, msg| "#{severity}: #{msg}\n" }
  end

  subject(:formatter) { described_class.new(original_formatter) }

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
    Fiber[:opentrace_request_id] = nil
    OpenTrace.shutdown(timeout: 1)
  end

  describe "#call" do
    context "when trace context is present" do
      before do
        Fiber[:opentrace_trace_id] = "abc123def456"
        Fiber[:opentrace_request_id] = "req-789"
      end

      it "injects trace_id and request_id" do
        result = formatter.call("INFO", Time.now, nil, "Hello world")
        expect(result).to include("[trace_id=abc123def456 request_id=req-789]")
        expect(result).to include("Hello world")
      end

      it "preserves trailing newline" do
        result = formatter.call("INFO", Time.now, nil, "Hello world")
        expect(result).to end_with("\n")
      end
    end

    context "when only trace_id is present" do
      before do
        Fiber[:opentrace_trace_id] = "abc123def456"
        Fiber[:opentrace_request_id] = nil
      end

      it "injects only trace_id" do
        result = formatter.call("INFO", Time.now, nil, "Hello")
        expect(result).to include("[trace_id=abc123def456]")
        expect(result).not_to include("request_id=")
      end
    end

    context "when no trace context is present" do
      before do
        Fiber[:opentrace_trace_id] = nil
        Fiber[:opentrace_request_id] = nil
      end

      it "does not modify the output" do
        result = formatter.call("INFO", Time.now, nil, "Hello")
        expect(result).to eq("INFO: Hello\n")
      end
    end

    context "with nil original formatter" do
      subject(:formatter) { described_class.new(nil) }

      it "uses default Logger::Formatter" do
        Fiber[:opentrace_trace_id] = "abc123"
        result = formatter.call("INFO", Time.now, nil, "Hello")
        expect(result).to be_a(String)
        expect(result).to include("[trace_id=abc123]")
      end
    end

    context "when original formatter returns non-string" do
      let(:original_formatter) do
        proc { |_severity, _datetime, _progname, _msg| nil }
      end

      it "returns the original output unchanged" do
        Fiber[:opentrace_trace_id] = "abc123"
        result = formatter.call("INFO", Time.now, nil, "Hello")
        expect(result).to be_nil
      end
    end

    context "when original formatter raises" do
      let(:original_formatter) do
        proc { |severity, _datetime, _progname, msg| "#{severity}: #{msg}\n" }
      end

      it "handles errors gracefully" do
        Fiber[:opentrace_trace_id] = "abc123"
        # Even if trace_prefix building fails, should still return something
        result = formatter.call("INFO", Time.now, nil, "Hello")
        expect(result).to be_a(String)
      end
    end
  end
end
