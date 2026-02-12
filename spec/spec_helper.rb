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
    c.sql_logging     = overrides[:sql_logging]     if overrides.key?(:sql_logging)
    c.request_summary = overrides[:request_summary]  if overrides.key?(:request_summary)
    c.memory_tracking = overrides[:memory_tracking]  if overrides.key?(:memory_tracking)
    c.http_tracking   = overrides[:http_tracking]    if overrides.key?(:http_tracking)
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
