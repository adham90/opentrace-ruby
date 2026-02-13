# frozen_string_literal: true

# This test uses REAL ActiveSupport classes (BroadcastLogger, TaggedLogging)
# to reproduce the exact Rails 7.1+ boot + request cycle.
# It verifies OpenTrace doesn't crash the app under any configuration.

require "stringio"
require "active_support"
require "active_support/tagged_logging"
require "active_support/broadcast_logger"
require "opentrace"
require_relative "../../lib/opentrace/trace_formatter"
require_relative "../../lib/opentrace/log_forwarder"

RSpec.describe "Real Rails boot simulation" do
  let(:output) { StringIO.new }

  before do
    OpenTrace.reset!
    stub_request(:any, /opentrace\.test/).to_return(status: 200, body: "{}")
    Fiber[:opentrace_trace_id] = nil
    Fiber[:opentrace_request_id] = nil
  end

  after do
    Fiber[:opentrace_trace_id] = nil
    Fiber[:opentrace_request_id] = nil
    OpenTrace.shutdown(timeout: 1)
  end

  def configure_all_features!
    OpenTrace.configure do |c|
      c.endpoint       = "https://opentrace.test"
      c.api_key        = "test-key"
      c.service        = "test-app"
      c.environment    = "production"
      c.flush_interval = 0.2
      c.min_level      = :debug
      c.log_forwarding       = true
      c.log_trace_injection  = true
      c.sql_logging          = true
      c.view_tracking        = true
      c.cache_tracking       = true
      c.deprecation_tracking = true
      c.detailed_request_log = true
      c.request_summary      = true
      c.timeline             = true
      c.memory_tracking      = true
      c.session_tracking     = true
      c.source_context       = true
      c.pii_scrubbing        = true
      c.sql_normalization    = true
      c.trace_propagation    = true
      c.sample_rate          = 1.0
    end
  end

  # Builds a logger exactly like Rails 7.1+ does
  def build_rails_logger
    logger = ActiveSupport::TaggedLogging.new(Logger.new(output))
    ActiveSupport::BroadcastLogger.new(logger)
  end

  # Simulates what the Railtie does during config.after_initialize
  def simulate_railtie_init!(broadcast_logger)
    # Step 1: Trace injection — replace formatter
    if OpenTrace.config.log_trace_injection
      original_formatter = broadcast_logger.formatter
      broadcast_logger.formatter = OpenTrace::TraceFormatter.new(original_formatter)
    end

    # Step 2: Log forwarding — add LogForwarder as broadcast target
    if OpenTrace.config.log_forwarding
      broadcast_logger.broadcast_to(OpenTrace::LogForwarder.new)
    end
  end

  # Simulates what Rails::Rack::Logger does on every request
  def simulate_rack_logger_request!(logger, request_id: "req-#{SecureRandom.hex(8)}")
    # Rails::Rack::Logger#call pushes tags at the start
    logger.push_tags(request_id)

    # Typical Rails request logging
    logger.info "Started GET /up for 10.0.0.1 at #{Time.now}"
    logger.info "Processing by HealthController#show as HTML"

    # Tagged logging block (used by many Rails internals)
    logger.tagged("ActionView") do
      logger.debug "  Rendering text template"
      logger.debug "  Rendered text template (0.1ms)"
    end

    logger.info "Completed 200 OK in 1ms (Views: 0.5ms)"

    # Rails::Rack::Logger#call pops tags at the end
    logger.pop_tags(1)
  end

  describe "boot with ALL features enabled" do
    before { configure_all_features! }

    it "initializes without error" do
      logger = build_rails_logger
      expect { simulate_railtie_init!(logger) }.not_to raise_error
    end

    it "survives push_tags/pop_tags (the v0.13.0 crash)" do
      logger = build_rails_logger
      simulate_railtie_init!(logger)

      expect { logger.push_tags("request_id:abc") }.not_to raise_error
      expect { logger.pop_tags(1) }.not_to raise_error
    end

    it "survives tagged blocks" do
      logger = build_rails_logger
      simulate_railtie_init!(logger)

      expect {
        logger.tagged("env:production", "host:web1") do
          logger.info "Inside tagged block"
        end
      }.not_to raise_error
    end

    it "survives a full request cycle" do
      logger = build_rails_logger
      simulate_railtie_init!(logger)

      expect { simulate_rack_logger_request!(logger) }.not_to raise_error
    end

    it "survives 50 sequential requests (like health checks)" do
      logger = build_rails_logger
      simulate_railtie_init!(logger)

      50.times do |i|
        expect { simulate_rack_logger_request!(logger) }.not_to raise_error
      end
    end

    it "produces log output with trace context" do
      logger = build_rails_logger
      simulate_railtie_init!(logger)

      Fiber[:opentrace_trace_id] = "trace-deadbeef"
      Fiber[:opentrace_request_id] = "req-12345678"

      logger.push_tags("req-12345678")
      logger.info "Health check OK"
      logger.pop_tags(1)

      log_output = output.string
      expect(log_output).to include("Health check OK")
      expect(log_output).to include("[trace_id=trace-deadbeef request_id=req-12345678]")
    end

    it "formatter still supports current_tags" do
      logger = build_rails_logger
      simulate_railtie_init!(logger)

      # The formatter should still track tags through TraceFormatter
      formatter = logger.formatter
      expect(formatter).to respond_to(:push_tags)
      expect(formatter).to respond_to(:pop_tags)
      expect(formatter).to respond_to(:current_tags)

      formatter.push_tags("tag1", "tag2")
      expect(formatter.current_tags).to include("tag1", "tag2")
      formatter.pop_tags(2)
    end

    it "survives clear_tags! (called by TaggedLogging#flush)" do
      logger = build_rails_logger
      simulate_railtie_init!(logger)

      logger.push_tags("tag1")
      expect { logger.clear_tags! }.not_to raise_error
    end

    it "survives flush (calls clear_tags! internally)" do
      logger = build_rails_logger
      simulate_railtie_init!(logger)

      logger.push_tags("tag1")
      logger.info "before flush"
      expect { logger.flush }.not_to raise_error
    end

    it "formatter supports tags_text" do
      logger = build_rails_logger
      simulate_railtie_init!(logger)

      formatter = logger.formatter
      expect(formatter).to respond_to(:tags_text)
      formatter.push_tags("env:test")
      expect(formatter.tags_text).to include("env:test")
      formatter.clear_tags!
    end
  end

  describe "boot with only log_forwarding (no trace injection)" do
    before do
      OpenTrace.configure do |c|
        c.endpoint       = "https://opentrace.test"
        c.api_key        = "test-key"
        c.service        = "test-app"
        c.flush_interval = 0.2
        c.log_forwarding       = true
        c.log_trace_injection  = false
      end
    end

    it "survives request cycle" do
      logger = build_rails_logger
      simulate_railtie_init!(logger)

      expect { simulate_rack_logger_request!(logger) }.not_to raise_error
    end
  end

  describe "boot with only trace injection (no forwarding)" do
    before do
      OpenTrace.configure do |c|
        c.endpoint       = "https://opentrace.test"
        c.api_key        = "test-key"
        c.service        = "test-app"
        c.flush_interval = 0.2
        c.log_forwarding       = false
        c.log_trace_injection  = true
      end
    end

    it "survives request cycle" do
      logger = build_rails_logger
      simulate_railtie_init!(logger)

      expect { simulate_rack_logger_request!(logger) }.not_to raise_error
    end
  end

  describe "LogForwarder in broadcast receives all method_missing calls" do
    before { configure_all_features! }

    it "responds to all methods BroadcastLogger might delegate" do
      forwarder = OpenTrace::LogForwarder.new
      # These are the methods Rails::Rack::Logger and TaggedLogging call
      %i[push_tags pop_tags current_tags tagged].each do |method|
        expect(forwarder).to respond_to(method),
          "LogForwarder must respond to #{method} to avoid NoMethodError from BroadcastLogger"
      end
    end
  end

  describe "TraceFormatter wrapping real TaggedLogging formatter" do
    it "delegates all tag methods to the real ActiveSupport formatter" do
      tagged_logger = ActiveSupport::TaggedLogging.new(Logger.new(output))
      original_formatter = tagged_logger.formatter

      trace_formatter = OpenTrace::TraceFormatter.new(original_formatter)

      # These must work — they're called by Rails::Rack::Logger via the logger
      trace_formatter.push_tags("request_id:abc")
      expect(trace_formatter.current_tags).to include("request_id:abc")

      trace_formatter.pop_tags(1)
      expect(trace_formatter.current_tags).to be_empty
    end

    it "tagged block works through TraceFormatter" do
      tagged_logger = ActiveSupport::TaggedLogging.new(Logger.new(output))
      original_formatter = tagged_logger.formatter

      trace_formatter = OpenTrace::TraceFormatter.new(original_formatter)

      called = false
      trace_formatter.tagged("env:test") do
        called = true
        expect(trace_formatter.current_tags).to include("env:test")
      end
      expect(called).to be true
      expect(trace_formatter.current_tags).to be_empty
    end
  end

  describe "edge cases" do
    before { configure_all_features! }

    it "handles push_tags with empty/nil tags" do
      logger = build_rails_logger
      simulate_railtie_init!(logger)

      expect { logger.push_tags("", nil, "valid") }.not_to raise_error
    end

    it "handles pop_tags with count 0" do
      logger = build_rails_logger
      simulate_railtie_init!(logger)

      logger.push_tags("tag1")
      expect { logger.pop_tags(0) }.not_to raise_error
      logger.pop_tags(1)
    end

    it "handles concurrent tagged blocks" do
      logger = build_rails_logger
      simulate_railtie_init!(logger)

      threads = 5.times.map do |i|
        Thread.new do
          10.times do
            logger.push_tags("thread-#{i}")
            logger.info "Hello from thread #{i}"
            logger.pop_tags(1)
          end
        end
      end

      expect { threads.each(&:join) }.not_to raise_error
    end
  end
end
