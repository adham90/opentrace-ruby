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
    c.endpoint    = overrides.fetch(:endpoint, "https://opentrace.test")
    c.api_key     = overrides.fetch(:api_key, "test-key-123")
    c.service     = overrides.fetch(:service, "test-service")
    c.environment = overrides.fetch(:environment, "test")
    c.timeout     = overrides.fetch(:timeout, 1.0)
    c.enabled     = overrides.fetch(:enabled, true)
  end
end
