# frozen_string_literal: true

RSpec.describe OpenTrace::LogForwarder do
  before do
    configure_opentrace!
    stub_request(:post, "https://opentrace.test/api/logs")
      .to_return(status: 201, body: '{"count":1}')
  end

  subject(:forwarder) { described_class.new }

  describe "#add" do
    it "forwards messages to OpenTrace" do
      forwarder.add(::Logger::INFO, "hello from broadcast")
      sleep 0.5

      expect(
        a_request(:post, "https://opentrace.test/api/logs")
          .with { |req|
            body = JSON.parse(req.body)
            body["level"] == "INFO" && body["message"] == "hello from broadcast"
          }
      ).to have_been_made
    end

    it "maps severity levels correctly" do
      {
        ::Logger::DEBUG   => "DEBUG",
        ::Logger::INFO    => "INFO",
        ::Logger::WARN    => "WARN",
        ::Logger::ERROR   => "ERROR",
        ::Logger::FATAL   => "FATAL",
        ::Logger::UNKNOWN => "UNKNOWN"
      }.each do |severity, expected_level|
        WebMock.reset!
        stub_request(:post, "https://opentrace.test/api/logs")
          .to_return(status: 201, body: '{"count":1}')

        forwarder.add(severity, "test #{expected_level}")
        sleep 0.5

        expect(
          a_request(:post, "https://opentrace.test/api/logs")
            .with { |req| JSON.parse(req.body)["level"] == expected_level }
        ).to have_been_made
      end
    end

    it "supports block form" do
      forwarder.add(::Logger::INFO) { "lazy message" }
      sleep 0.5

      expect(
        a_request(:post, "https://opentrace.test/api/logs")
          .with { |req| JSON.parse(req.body)["message"] == "lazy message" }
      ).to have_been_made
    end

    it "supports progname fallback" do
      forwarder.add(::Logger::INFO, nil, "progname message")
      sleep 0.5

      expect(
        a_request(:post, "https://opentrace.test/api/logs")
          .with { |req| JSON.parse(req.body)["message"] == "progname message" }
      ).to have_been_made
    end

    it "does not forward empty messages" do
      WebMock.reset!
      stub_request(:post, "https://opentrace.test/api/logs")
        .to_return(status: 201, body: '{"count":1}')

      forwarder.add(::Logger::INFO, "")
      forwarder.add(::Logger::INFO, "   ")
      sleep 0.5

      expect(a_request(:post, "https://opentrace.test/api/logs")).not_to have_been_made
    end

    it "respects log level filtering" do
      forwarder.level = ::Logger::WARN

      WebMock.reset!
      stub_request(:post, "https://opentrace.test/api/logs")
        .to_return(status: 201, body: '{"count":1}')

      forwarder.add(::Logger::DEBUG, "should be filtered")
      forwarder.add(::Logger::INFO, "also filtered")
      sleep 0.5

      expect(a_request(:post, "https://opentrace.test/api/logs")).not_to have_been_made
    end

    it "never raises even if OpenTrace raises" do
      allow(OpenTrace).to receive(:log).and_raise(RuntimeError, "boom")
      expect { forwarder.add(::Logger::INFO, "safe") }.not_to raise_error
    end

    it "never raises when OpenTrace is disabled" do
      OpenTrace.disable!
      expect { forwarder.add(::Logger::INFO, "test") }.not_to raise_error
    end

    it "returns true" do
      expect(forwarder.add(::Logger::INFO, "msg")).to eq(true)
    end
  end

  describe "#close" do
    it "does not raise" do
      expect { forwarder.close }.not_to raise_error
    end
  end

  describe "level defaults" do
    it "defaults to DEBUG level" do
      expect(forwarder.level).to eq(::Logger::DEBUG)
    end
  end
end
