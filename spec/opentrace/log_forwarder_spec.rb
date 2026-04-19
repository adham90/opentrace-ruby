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
            body = parse_log_body(req)
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
        stub_request(:any, /opentrace\.test/)
          .to_return(status: 200, body: '{"count":0}')
        stub_request(:post, "https://opentrace.test/api/logs")
          .to_return(status: 201, body: '{"count":1}')

        forwarder.add(severity, "test #{expected_level}")
        sleep 0.5

        expect(
          a_request(:post, "https://opentrace.test/api/logs")
            .with { |req| parse_log_body(req)["level"] == expected_level }
        ).to have_been_made
      end
    end

    it "supports block form" do
      forwarder.add(::Logger::INFO) { "lazy message" }
      sleep 0.5

      expect(
        a_request(:post, "https://opentrace.test/api/logs")
          .with { |req| parse_log_body(req)["message"] == "lazy message" }
      ).to have_been_made
    end

    it "supports progname fallback" do
      forwarder.add(::Logger::INFO, nil, "progname message")
      sleep 0.5

      expect(
        a_request(:post, "https://opentrace.test/api/logs")
          .with { |req| parse_log_body(req)["message"] == "progname message" }
      ).to have_been_made
    end

    it "does not forward empty messages" do
      WebMock.reset!
      stub_request(:any, /opentrace\.test/)
        .to_return(status: 200, body: '{"count":0}')
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
      stub_request(:any, /opentrace\.test/)
        .to_return(status: 200, body: '{"count":0}')
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
    it "matches OpenTrace min_level (defaults to :debug)" do
      expect(forwarder.level).to eq(::Logger::DEBUG)
    end

    it "uses INFO level when OpenTrace min_level is :info" do
      OpenTrace.reset!
      configure_opentrace!(min_level: :info)
      f = described_class.new
      expect(f.level).to eq(::Logger::INFO)
    end

    it "uses WARN level when OpenTrace min_level is :warn" do
      OpenTrace.reset!
      configure_opentrace!(min_level: :warn)
      f = described_class.new
      expect(f.level).to eq(::Logger::WARN)
    end

    it "filters DEBUG messages when min_level is :info" do
      OpenTrace.reset!
      configure_opentrace!(min_level: :info)
      f = described_class.new

      WebMock.reset!
      stub_request(:any, /opentrace\.test/)
        .to_return(status: 200, body: '{"count":0}')
      stub_request(:post, "https://opentrace.test/api/logs")
        .to_return(status: 201, body: '{"count":1}')

      f.add(::Logger::DEBUG, "should be filtered by forwarder level")
      sleep 0.5

      expect(a_request(:post, "https://opentrace.test/api/logs")).not_to have_been_made
    end

    it "does not evaluate lazy blocks for filtered levels" do
      OpenTrace.reset!
      configure_opentrace!(min_level: :info)
      f = described_class.new

      block_evaluated = false
      f.add(::Logger::DEBUG) { block_evaluated = true; "expensive" }

      expect(block_evaluated).to be false
    end
  end

  describe "TaggedLogging interface" do
    it "responds to push_tags" do
      expect(forwarder).to respond_to(:push_tags)
    end

    it "responds to pop_tags" do
      expect(forwarder).to respond_to(:pop_tags)
    end

    it "responds to current_tags" do
      expect(forwarder).to respond_to(:current_tags)
    end

    it "does NOT respond to :tagged (regression guard — see log_forwarder.rb)" do
      # If LogForwarder responds to :tagged, Rails' BroadcastLogger#method_missing
      # routes logger.tagged(...) { block } through every sink and each sink's
      # tagged yields the block — so the block runs once per sink. For
      # ActiveJob's around_enqueue / around_perform (both wrapped in
      # logger.tagged), that means perform_later and perform_now fire N times
      # where N is the number of sinks. Not responding to :tagged makes
      # method_missing filter us out and only the real TaggedLogging sink runs
      # the block exactly once.
      expect(forwarder).not_to respond_to(:tagged)
    end

    it "push_tags does not raise" do
      expect { forwarder.push_tags("request_id:abc", "host:web1") }.not_to raise_error
    end

    it "pop_tags does not raise" do
      expect { forwarder.pop_tags(2) }.not_to raise_error
    end

    it "current_tags returns empty array" do
      expect(forwarder.current_tags).to eq([])
    end

    it "routes under BroadcastLogger without duplicating the block" do
      # Reproduces the Rails 7.1+ BroadcastLogger shape. BroadcastLogger's
      # `tagged` is not in LOGGER_METHODS, so it goes through method_missing,
      # which iterates every sink that responds to :tagged and calls each
      # one with the same block — there is NO block-cache guard here (unlike
      # `dispatch`). If LogForwarder also responds to :tagged, the block
      # fires twice.
      require "active_support"
      require "active_support/logger_silence"
      require "active_support/broadcast_logger"

      tagged_sink = Class.new(::Logger) do
        def tagged(*_tags)
          yield self
        end
      end.new(IO::NULL)

      broadcast = ActiveSupport::BroadcastLogger.new(tagged_sink, forwarder)

      invocations = 0
      broadcast.tagged("req:abc") { invocations += 1 }
      expect(invocations).to eq(1)
    end

    it "clear_tags! does not raise" do
      expect { forwarder.clear_tags! }.not_to raise_error
    end

    it "tags_text returns empty string" do
      expect(forwarder.tags_text).to eq("")
    end

    it "flush does not raise" do
      expect { forwarder.flush }.not_to raise_error
    end
  end
end
