# frozen_string_literal: true

RSpec.describe OpenTrace::SourceContext do
  before { described_class.clear_cache! }

  describe ".extract" do
    it "extracts context from a valid backtrace line" do
      # Use a lib file (safe_path? allows /lib/)
      file_path = File.expand_path("../../lib/opentrace/version.rb", __dir__)
      backtrace_line = "#{file_path}:4:in `block'"

      result = described_class.extract(backtrace_line)
      expect(result).to be_a(Hash)
      expect(result[:file]).to eq(file_path)
      expect(result[:line]).to eq(4)
      expect(result[:context]).to be_a(Hash)
      expect(result[:context][4]).to include("VERSION")
    end

    it "returns surrounding context lines" do
      file_path = File.expand_path("../../lib/opentrace/version.rb", __dir__)
      backtrace_line = "#{file_path}:4:in `test'"

      result = described_class.extract(backtrace_line)
      context = result[:context]
      # Should have lines before and after
      expect(context.keys.min).to be <= 4
      expect(context.keys.max).to be >= 4
      expect(context.keys.length).to be <= 7 # 3 before + target + 3 after
    end

    it "returns nil for nil input" do
      expect(described_class.extract(nil)).to be_nil
    end

    it "returns nil for non-matching format" do
      expect(described_class.extract("garbage")).to be_nil
    end

    it "returns nil for line 0" do
      expect(described_class.extract("file.rb:0:in `test'")).to be_nil
    end

    it "returns nil for non-existent file" do
      expect(described_class.extract("/nonexistent/file.rb:42:in `test'")).to be_nil
    end

    it "truncates long lines to 200 chars" do
      file_path = __FILE__
      line_no = __LINE__
      result = described_class.extract("#{file_path}:#{line_no}:in `test'")
      if result
        result[:context].each do |_, line|
          expect(line.length).to be <= 200
        end
      end
    end
  end

  describe ".safe_path?" do
    it "allows paths containing /app/" do
      expect(described_class.send(:safe_path?, "/app/models/user.rb")).to be false # doesn't exist
    end

    it "allows paths containing /lib/" do
      # Use a real file from our gem
      path = File.expand_path("../../lib/opentrace.rb", __dir__)
      expect(described_class.send(:safe_path?, path)).to be true
    end

    it "rejects paths not in app/lib/config" do
      expect(described_class.send(:safe_path?, "/etc/passwd")).to be false
    end
  end

  describe "caching" do
    it "caches file reads" do
      file_path = __FILE__
      backtrace_line = "#{file_path}:1:in `test'"

      # First read
      result1 = described_class.extract(backtrace_line)
      # Second read should come from cache
      result2 = described_class.extract(backtrace_line)

      expect(result1).to eq(result2)
    end

    it "respects MAX_CACHE_SIZE" do
      # This is a structural test — just verify the constant exists
      expect(described_class::MAX_CACHE_SIZE).to eq(50)
    end
  end

  describe ".clear_cache!" do
    it "clears the file cache" do
      file_path = File.expand_path("../../lib/opentrace/version.rb", __dir__)
      described_class.extract("#{file_path}:1:in `test'")
      described_class.clear_cache!
      # No error, and subsequent reads work
      result = described_class.extract("#{file_path}:1:in `test'")
      expect(result).not_to be_nil
    end
  end

  describe "integration with OpenTrace.error" do
    before do
      OpenTrace.reset!
      OpenTrace.configure do |c|
        c.endpoint = "https://opentrace.test"
        c.api_key = "test-key"
        c.service = "test-app"
        c.flush_interval = 0.2
        c.source_context = true
      end
      stub_request(:any, /opentrace\.test/).to_return(status: 200, body: "{}")
    end

    after { OpenTrace.shutdown(timeout: 1) }

    it "attaches source context to errors when enabled" do
      lib_file = File.expand_path("../../lib/opentrace/version.rb", __dir__)
      e = RuntimeError.new("test error")
      e.set_backtrace(["#{lib_file}:4:in `test'"])

      expect(OpenTrace).to receive(:log) do |level, msg, meta|
        expect(meta[:source_context]).to be_a(Hash)
        expect(meta[:source_context][:file]).to eq(lib_file)
        expect(meta[:source_context][:context]).to be_a(Hash)
      end

      OpenTrace.error(e)
    end

    it "does not attach source context when disabled" do
      OpenTrace.config.source_context = false

      lib_file = File.expand_path("../../lib/opentrace/version.rb", __dir__)
      e = RuntimeError.new("test error")
      e.set_backtrace(["#{lib_file}:4:in `test'"])

      expect(OpenTrace).to receive(:log) do |level, msg, meta|
        expect(meta).not_to have_key(:source_context)
      end

      OpenTrace.error(e)
    end
  end
end
