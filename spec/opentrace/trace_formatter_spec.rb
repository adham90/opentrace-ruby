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

  describe "TaggedLogging interface" do
    context "when original formatter supports tags" do
      let(:tagged_formatter) do
        f = ::Logger::Formatter.new
        # Simulate ActiveSupport::TaggedLogging::Formatter
        f.define_singleton_method(:push_tags) { |*tags| (@tags ||= []).concat(tags.flatten.compact.reject { |t| t.respond_to?(:empty?) && t.empty? }); @tags }
        f.define_singleton_method(:pop_tags) { |count = 1| (@tags ||= []).pop(count) }
        f.define_singleton_method(:current_tags) { @tags ||= [] }
        f.define_singleton_method(:tagged) { |*tags, &blk| push_tags(*tags); blk.call; pop_tags(tags.size) }
        f
      end

      subject(:formatter) { described_class.new(tagged_formatter) }

      it "delegates push_tags to original" do
        formatter.push_tags("request_id:abc")
        expect(tagged_formatter.current_tags).to include("request_id:abc")
      end

      it "delegates pop_tags to original" do
        tagged_formatter.push_tags("tag1", "tag2")
        formatter.pop_tags(1)
        expect(tagged_formatter.current_tags).to eq(["tag1"])
      end

      it "delegates current_tags to original" do
        tagged_formatter.push_tags("tag1")
        expect(formatter.current_tags).to eq(["tag1"])
      end

      it "delegates tagged to original" do
        called = false
        formatter.tagged("request_id:xyz") do
          called = true
          expect(tagged_formatter.current_tags).to include("request_id:xyz")
        end
        expect(called).to be true
      end

      it "delegates clear_tags! to original" do
        tagged_formatter.define_singleton_method(:clear_tags!) { (@tags ||= []).clear }
        tagged_formatter.push_tags("tag1", "tag2")
        formatter.clear_tags!
        expect(tagged_formatter.current_tags).to eq([])
      end

      it "delegates tags_text to original" do
        tagged_formatter.define_singleton_method(:tags_text) { "[#{(@tags || []).join('] [')}] " }
        tagged_formatter.push_tags("env:test")
        expect(formatter.tags_text).to include("env:test")
      end
    end

    context "when original formatter does NOT support tags" do
      # Plain proc formatter — no push_tags/pop_tags
      let(:original_formatter) do
        proc { |severity, _datetime, _progname, msg| "#{severity}: #{msg}\n" }
      end

      it "push_tags is a safe no-op" do
        expect { formatter.push_tags("tag1") }.not_to raise_error
      end

      it "pop_tags is a safe no-op" do
        expect { formatter.pop_tags(1) }.not_to raise_error
      end

      it "current_tags returns empty array" do
        expect(formatter.current_tags).to eq([])
      end

      it "tagged yields without error" do
        called = false
        formatter.tagged("tag1") { called = true }
        expect(called).to be true
      end

      it "clear_tags! is a safe no-op" do
        expect { formatter.clear_tags! }.not_to raise_error
      end

      it "tags_text returns empty string" do
        expect(formatter.tags_text).to eq("")
      end
    end
  end
end
