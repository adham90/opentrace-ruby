# frozen_string_literal: true

require "stringio"

RSpec.describe OpenTrace::Logger do
  let(:io) { StringIO.new }
  let(:wrapped) { ::Logger.new(io) }

  before { configure_opentrace! }

  subject(:logger) { described_class.new(wrapped) }

  describe "#add" do
    before do
      stub_request(:post, "https://opentrace.test/api/logs")
        .to_return(status: 201, body: '{"count":1}')
    end

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
            body = JSON.parse(req.body)
            body["level"] == "ERROR" && body["message"] == "something broke"
          }
      ).to have_been_made
    end

    it "handles all severity levels" do
      %i[debug info warn error fatal].each do |level|
        logger.send(level, "#{level} message")
      end

      expect(io.string).to include("debug message")
      expect(io.string).to include("fatal message")
    end

    it "never raises even if OpenTrace fails" do
      OpenTrace.reset!
      # No configuration - should not raise
      expect { logger.info("test") }.not_to raise_error
    end

    it "supports block form" do
      logger.info { "computed message" }
      expect(io.string).to include("computed message")
    end
  end

  describe "#flush" do
    it "delegates to wrapped logger" do
      expect(wrapped).to receive(:flush)
      logger.flush
    end
  end

  describe "#close" do
    it "delegates to wrapped logger" do
      expect(wrapped).to receive(:close)
      logger.close
    end
  end
end
