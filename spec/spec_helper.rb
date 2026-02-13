# frozen_string_literal: true

require "webmock/rspec"
require "opentrace"

WebMock.disable_net_connect!

RSpec.configure do |config|
  config.before(:each) do
    # Stub all requests to the test endpoint as a safety net
    stub_request(:any, /opentrace\.test/)
      .to_return(status: 200, body: '{"count":0}')

    # Clean up Fiber-local state from previous tests
    Fiber[:opentrace_request_id] = nil
    Fiber[:opentrace_sql_count] = nil
    Fiber[:opentrace_sql_total_ms] = nil
    Fiber[:opentrace_collector] = nil
    Fiber[:opentrace_cached_context] = nil
    Fiber[:opentrace_logging] = nil
    Fiber[:opentrace_http_tracking_disabled] = nil
    Fiber[:opentrace_trace_id] = nil
    Fiber[:opentrace_span_id] = nil
    Fiber[:opentrace_parent_span_id] = nil

    OpenTrace.reset!
  end

  config.after(:each) do
    OpenTrace.shutdown(timeout: 2)
  end

  config.order = :random
end

def configure_opentrace!(overrides = {})
  OpenTrace.configure do |c|
    c.endpoint       = overrides.fetch(:endpoint, "https://opentrace.test")
    c.api_key        = overrides.fetch(:api_key, "test-key-123")
    c.service        = overrides.fetch(:service, "test-service")
    c.environment    = overrides.fetch(:environment, "test")
    c.timeout        = overrides.fetch(:timeout, 1.0)
    c.enabled        = overrides.fetch(:enabled, true)
    c.flush_interval = overrides.fetch(:flush_interval, 0.2) # fast flush for tests
    c.batch_size     = overrides.fetch(:batch_size, 50)
    c.compression    = overrides.fetch(:compression, false) # disable compression in tests by default
    c.min_level      = overrides.fetch(:min_level, :debug)
    c.context        = overrides[:context] if overrides.key?(:context)
    # Only override these if explicitly provided — preserve Config defaults otherwise
    c.sql_logging          = overrides[:sql_logging]          if overrides.key?(:sql_logging)
    c.request_summary      = overrides[:request_summary]      if overrides.key?(:request_summary)
    c.memory_tracking      = overrides[:memory_tracking]      if overrides.key?(:memory_tracking)
    c.http_tracking        = overrides[:http_tracking]        if overrides.key?(:http_tracking)
    c.log_forwarding       = overrides[:log_forwarding]       if overrides.key?(:log_forwarding)
    c.view_tracking        = overrides[:view_tracking]        if overrides.key?(:view_tracking)
    c.cache_tracking       = overrides[:cache_tracking]       if overrides.key?(:cache_tracking)
    c.deprecation_tracking = overrides[:deprecation_tracking] if overrides.key?(:deprecation_tracking)
    c.detailed_request_log = overrides[:detailed_request_log] if overrides.key?(:detailed_request_log)
    c.timeline             = overrides[:timeline]             if overrides.key?(:timeline)
    c.timeline_max_events  = overrides[:timeline_max_events]  if overrides.key?(:timeline_max_events)
    c.sample_rate          = overrides[:sample_rate]          if overrides.key?(:sample_rate)
    c.sampler              = overrides[:sampler]              if overrides.key?(:sampler)
    c.before_send          = overrides[:before_send]          if overrides.key?(:before_send)
    c.ignore_paths         = overrides[:ignore_paths]         if overrides.key?(:ignore_paths)
  end
end

# Helper to decompress gzip body if needed
def decompress_body(raw_body)
  gz = Zlib::GzipReader.new(StringIO.new(raw_body))
  gz.read
rescue Zlib::GzipFile::Error
  raw_body
ensure
  gz&.close
end

# Helper to parse batch body from request (payloads are always sent as arrays)
# Handles both compressed and uncompressed bodies
def parse_log_body(req)
  json = decompress_body(req.body)
  body = JSON.parse(json)
  body.is_a?(Array) ? body.first : body
end
