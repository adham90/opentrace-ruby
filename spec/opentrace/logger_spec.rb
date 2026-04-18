# frozen_string_literal: true

require "stringio"

RSpec.describe OpenTrace::Logger do
  let(:io) { StringIO.new }
  let(:wrapped) { ::Logger.new(io) }

  before do
    configure_opentrace!
    stub_request(:post, "https://opentrace.test/api/logs")
      .to_return(status: 201, body: '{"count":1}')
  end

  subject(:logger) { described_class.new(wrapped) }

  describe "#add" do
    it "delegates to the wrapped logger" do
      logger.info("hello world")
      expect(io.string).to include("hello world")
    end

    it "forwards to OpenTrace" do
      logger.error("something broke")
      sleep 0.5

      expect(
        a_request(:post, "https://opentrace.test/api/logs")
          .with { |req|
            body = parse_log_body(req)
            body["level"] == "ERROR" && body["message"] == "something broke"
          }
      ).to have_been_made
    end

    it "maps DEBUG severity correctly" do
      wrapped.level = ::Logger::DEBUG
      logger.debug("debug msg")
      sleep 0.5

      expect(
        a_request(:post, "https://opentrace.test/api/logs")
          .with { |req| parse_log_body(req)["level"] == "DEBUG" }
      ).to have_been_made
    end

    it "maps INFO severity correctly" do
      logger.info("info msg")
      sleep 0.5

      expect(
        a_request(:post, "https://opentrace.test/api/logs")
          .with { |req| parse_log_body(req)["level"] == "INFO" }
      ).to have_been_made
    end

    it "maps WARN severity correctly" do
      logger.warn("warn msg")
      sleep 0.5

      expect(
        a_request(:post, "https://opentrace.test/api/logs")
          .with { |req| parse_log_body(req)["level"] == "WARN" }
      ).to have_been_made
    end

    it "maps ERROR severity correctly" do
      logger.error("error msg")
      sleep 0.5

      expect(
        a_request(:post, "https://opentrace.test/api/logs")
          .with { |req| parse_log_body(req)["level"] == "ERROR" }
      ).to have_been_made
    end

    it "maps FATAL severity correctly" do
      logger.fatal("fatal msg")
      sleep 0.5

      expect(
        a_request(:post, "https://opentrace.test/api/logs")
          .with { |req| parse_log_body(req)["level"] == "FATAL" }
      ).to have_been_made
    end

    it "writes all severity levels to the wrapped logger" do
      wrapped.level = ::Logger::DEBUG
      %i[debug info warn error fatal].each do |level|
        logger.send(level, "#{level} message")
      end

      expect(io.string).to include("debug message")
      expect(io.string).to include("info message")
      expect(io.string).to include("warn message")
      expect(io.string).to include("error message")
      expect(io.string).to include("fatal message")
    end

    it "supports block form" do
      logger.info { "computed message" }
      expect(io.string).to include("computed message")
    end

    it "evaluates block form messages only once" do
      evaluations = 0

      logger.info { evaluations += 1; "computed once" }

      expect(evaluations).to eq(1)
      expect(io.string).to include("computed once")
    end

    it "does not evaluate filtered lazy blocks for forwarding" do
      wrapped.level = ::Logger::WARN
      filtered_logger = described_class.new(wrapped)
      evaluations = 0

      filtered_logger.info { evaluations += 1; "filtered" }

      expect(evaluations).to eq(0)
    end

    it "forwards block form messages to OpenTrace" do
      logger.info { "lazy message" }
      sleep 0.5

      expect(
        a_request(:post, "https://opentrace.test/api/logs")
          .with { |req| parse_log_body(req)["message"] == "lazy message" }
      ).to have_been_made
    end

    it "does not forward empty messages" do
      WebMock.reset!
      stub_request(:post, "https://opentrace.test/api/logs")
        .to_return(status: 201, body: '{"count":1}')

      logger.info("")
      logger.info("   ")
      sleep 0.5

      expect(a_request(:post, "https://opentrace.test/api/logs")).not_to have_been_made
    end

    it "never raises even if OpenTrace is not configured" do
      OpenTrace.reset!
      expect { logger.info("test") }.not_to raise_error
      expect(io.string).to include("test")
    end

    it "never raises even if OpenTrace is disabled" do
      OpenTrace.disable!
      expect { logger.error("test") }.not_to raise_error
      expect(io.string).to include("test")
    end

    it "still delegates to wrapped logger when OpenTrace raises" do
      allow(OpenTrace).to receive(:log).and_raise(RuntimeError, "boom")
      logger.info("still works")
      expect(io.string).to include("still works")
    end
  end

  describe "default metadata" do
    it "includes default metadata in every log" do
      meta_logger = described_class.new(wrapped, metadata: { component: "worker" })
      meta_logger.info("with defaults")
      sleep 0.5

      expect(
        a_request(:post, "https://opentrace.test/api/logs")
          .with { |req|
            body = parse_log_body(req)
            body["metadata"]["component"] == "worker"
          }
      ).to have_been_made
    end
  end

  describe "level inheritance" do
    it "inherits level from wrapped logger" do
      wrapped.level = ::Logger::WARN
      new_logger = described_class.new(wrapped)
      expect(new_logger.level).to eq(::Logger::WARN)
    end
  end

  describe "#flush" do
    it "delegates to wrapped logger" do
      expect(wrapped).to receive(:flush)
      logger.flush
    end

    it "does not raise if wrapped logger lacks flush" do
      basic = Object.new
      def basic.level; 1; end
      def basic.add(*); end

      basic_logger = described_class.new(basic)
      expect { basic_logger.flush }.not_to raise_error
    end
  end

  describe "#close" do
    it "delegates to wrapped logger" do
      expect(wrapped).to receive(:close)
      logger.close
    end
  end

  describe "#formatter" do
    it "proxies formatter to wrapped logger" do
      custom_formatter = proc { |_sev, _dt, _prog, msg| "CUSTOM: #{msg}\n" }
      logger.formatter = custom_formatter
      expect(wrapped.formatter).to eq(custom_formatter)
    end

    it "reads formatter from wrapped logger" do
      custom_formatter = proc { |_sev, _dt, _prog, msg| msg }
      logger # trigger creation so super(nil) runs first
      wrapped.formatter = custom_formatter
      expect(logger.formatter).to eq(custom_formatter)
    end
  end
end
