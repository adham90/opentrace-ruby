# frozen_string_literal: true

require "stringio"
require "securerandom"
require_relative "rails_spec_helper"
require_relative "../../lib/opentrace/trace_formatter"

# Reproduces the exact crash from v0.13.0:
#   NoMethodError: undefined method 'push_tags' for an instance of OpenTrace::TraceFormatter
#
# The call chain in Rails 7.1+:
#   1. Rails::Rack::Logger calls push_tags on the BroadcastLogger
#   2. BroadcastLogger delegates push_tags to all sinks via method_missing
#   3. Each TaggedLogging-extended logger calls formatter.push_tags
#   4. TraceFormatter (which replaced the original formatter) didn't have push_tags → crash
RSpec.describe "TaggedLogging compatibility" do
  before do
    configure_opentrace!
    stub_request(:post, "https://opentrace.test/api/logs")
      .to_return(status: 201, body: '{"count":1}')
  end

  # Simulates what Rails 7.1+ does: a logger wrapped with TaggedLogging
  # that has a formatter with push_tags/pop_tags/current_tags
  def build_tagged_logger
    logger = ::Logger.new(StringIO.new)
    # Simulate ActiveSupport::TaggedLogging::Formatter on the formatter
    formatter = logger.formatter || ::Logger::Formatter.new
    formatter.define_singleton_method(:push_tags) do |*tags|
      (@tags ||= []).concat(tags.flatten.compact.reject { |t| t.respond_to?(:empty?) && t.empty? })
      @tags
    end
    formatter.define_singleton_method(:pop_tags) do |count = 1|
      (@tags ||= []).pop(count)
    end
    formatter.define_singleton_method(:current_tags) do
      @tags ||= []
    end
    formatter.define_singleton_method(:tagged) do |*tags, &block|
      push_tags(*tags)
      block.call
    ensure
      pop_tags(tags.size)
    end
    logger.formatter = formatter

    # Simulate TaggedLogging mixin on the logger itself
    logger.define_singleton_method(:push_tags) do |*tags|
      self.formatter.push_tags(*tags)
    end
    logger.define_singleton_method(:pop_tags) do |count = 1|
      self.formatter.pop_tags(count)
    end
    logger.define_singleton_method(:tagged) do |*tags, &block|
      self.formatter.push_tags(*tags)
      block.call
    ensure
      self.formatter.pop_tags(tags.size)
    end

    logger
  end

  # Simulates a more realistic BroadcastLogger that delegates method_missing
  # like Rails 7.1+ does (blindly forwards to all broadcasts)
  def build_broadcast_logger(primary)
    broadcast = Object.new
    broadcast.instance_variable_set(:@primary, primary)
    broadcast.instance_variable_set(:@broadcasts, [primary])

    broadcast.define_singleton_method(:broadcast_to) do |target|
      @broadcasts << target
    end

    broadcast.define_singleton_method(:respond_to?) do |method, include_private = false|
      method == :broadcast_to || @primary.respond_to?(method) || super(method, include_private)
    end

    broadcast.define_singleton_method(:respond_to_missing?) do |method, include_private = false|
      @primary.respond_to?(method, include_private) || super
    end

    broadcast.define_singleton_method(:method_missing) do |name, *args, **kwargs, &block|
      @broadcasts.each do |logger|
        logger.send(name, *args, **kwargs, &block) if logger.respond_to?(name)
      end
    end

    broadcast.define_singleton_method(:formatter) do
      @primary.formatter
    end

    broadcast.define_singleton_method(:formatter=) do |f|
      @broadcasts.each { |logger| logger.formatter = f if logger.respond_to?(:formatter=) }
    end

    broadcast.define_singleton_method(:level) do
      @primary.level
    end

    broadcast
  end

  describe "TraceFormatter with TaggedLogging formatter" do
    it "does not crash when push_tags is called (the v0.13.0 bug)" do
      tagged_logger = build_tagged_logger
      broadcast = build_broadcast_logger(tagged_logger)
      Rails.logger = broadcast

      # This is what the Railtie does: replace formatter with TraceFormatter
      original_formatter = Rails.logger.formatter
      Rails.logger.formatter = OpenTrace::TraceFormatter.new(original_formatter)

      # This is what Rails::Rack::Logger does on every request — the crash point
      expect { Rails.logger.push_tags("request_id:abc123") }.not_to raise_error
    end

    it "preserves tag functionality through TraceFormatter" do
      tagged_logger = build_tagged_logger
      broadcast = build_broadcast_logger(tagged_logger)
      Rails.logger = broadcast

      original_formatter = Rails.logger.formatter
      trace_formatter = OpenTrace::TraceFormatter.new(original_formatter)
      Rails.logger.formatter = trace_formatter

      Rails.logger.push_tags("request_id:abc123", "host:web1")
      expect(trace_formatter.current_tags).to eq(["request_id:abc123", "host:web1"])

      Rails.logger.pop_tags(1)
      expect(trace_formatter.current_tags).to eq(["request_id:abc123"])

      Rails.logger.pop_tags(1)
      expect(trace_formatter.current_tags).to eq([])
    end
  end

  describe "LogForwarder as broadcast target with TaggedLogging" do
    it "does not crash when push_tags is delegated via BroadcastLogger" do
      tagged_logger = build_tagged_logger
      broadcast = build_broadcast_logger(tagged_logger)
      Rails.logger = broadcast

      # Add LogForwarder as broadcast target (what Railtie does)
      forwarder = OpenTrace::LogForwarder.new
      broadcast.broadcast_to(forwarder)

      # BroadcastLogger will delegate push_tags to ALL sinks, including LogForwarder
      expect { Rails.logger.push_tags("request_id:abc123") }.not_to raise_error
      expect { Rails.logger.pop_tags(1) }.not_to raise_error
    end
  end

  describe "full stack: TraceFormatter + LogForwarder + BroadcastLogger" do
    it "survives the exact Rails::Rack::Logger call chain" do
      tagged_logger = build_tagged_logger
      broadcast = build_broadcast_logger(tagged_logger)
      Rails.logger = broadcast

      # Step 1: Railtie replaces formatter with TraceFormatter (log_trace_injection)
      original_formatter = Rails.logger.formatter
      Rails.logger.formatter = OpenTrace::TraceFormatter.new(original_formatter)

      # Step 2: Railtie adds LogForwarder as broadcast target (log_forwarding)
      forwarder = OpenTrace::LogForwarder.new
      broadcast.broadcast_to(forwarder)

      # Step 3: Simulate Rails::Rack::Logger#call (runs on every request)
      # This is the exact sequence that crashed in v0.13.0
      expect {
        Rails.logger.push_tags("request_id:#{SecureRandom.uuid}")
        Rails.logger.info("Started GET /up for 10.0.0.1")
        Rails.logger.info("Processing by RailsController#up as HTML")
        Rails.logger.info("  Rendering text template")
        Rails.logger.info("Completed 200 OK in 1ms")
        Rails.logger.pop_tags(1)
      }.not_to raise_error
    end

    it "logs correctly with trace context injected" do
      tagged_logger = build_tagged_logger
      output = tagged_logger.instance_variable_get(:@logdev).dev
      broadcast = build_broadcast_logger(tagged_logger)
      Rails.logger = broadcast

      original_formatter = Rails.logger.formatter
      Rails.logger.formatter = OpenTrace::TraceFormatter.new(original_formatter)
      broadcast.broadcast_to(OpenTrace::LogForwarder.new)

      Fiber[:opentrace_trace_id] = "trace-abc123"
      Fiber[:opentrace_request_id] = "req-xyz789"

      Rails.logger.push_tags("request_id:test")
      Rails.logger.info("Health check OK")
      Rails.logger.pop_tags(1)

      log_output = output.string
      expect(log_output).to include("Health check OK")
      expect(log_output).to include("[trace_id=trace-abc123 request_id=req-xyz789]")
    ensure
      Fiber[:opentrace_trace_id] = nil
      Fiber[:opentrace_request_id] = nil
    end

    it "handles multiple push/pop cycles (multiple requests)" do
      tagged_logger = build_tagged_logger
      broadcast = build_broadcast_logger(tagged_logger)
      Rails.logger = broadcast

      original_formatter = Rails.logger.formatter
      Rails.logger.formatter = OpenTrace::TraceFormatter.new(original_formatter)
      broadcast.broadcast_to(OpenTrace::LogForwarder.new)

      # Simulate 10 sequential requests (like health checks hitting /up)
      10.times do |i|
        expect {
          Rails.logger.push_tags("request_id:req-#{i}")
          Rails.logger.info("Request #{i}")
          Rails.logger.pop_tags(1)
        }.not_to raise_error
      end
    end
  end
end
