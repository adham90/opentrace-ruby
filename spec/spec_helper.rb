# frozen_string_literal: true

require "webmock/rspec"
require "opentrace"

WebMock.disable_net_connect!

RSpec.configure do |config|
  config.before(:each) do
    # Stub all requests to the test endpoint as a safety net
    stub_request(:any, /opentrace\.test/)
      .to_return(status: 200, body: '{"count":0}')

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
