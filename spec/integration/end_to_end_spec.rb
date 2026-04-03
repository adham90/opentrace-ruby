# frozen_string_literal: true
require "stringio"

RSpec.describe "End-to-end integration" do
  before { stub_request(:post, "https://opentrace.test/api/logs").to_return(status: 201, body: '{"count":1}') }

  it "sends a well-formed payload" do
    configure_opentrace!(service: "integration-svc", environment: "test")
    OpenTrace.log("ERROR", "Integration test error", { user_id: 99 })
    OpenTrace.shutdown(timeout: 5)
    expect(a_request(:post, "https://opentrace.test/api/logs").with { |req|
      body = parse_log_body(req)
      body["level"] == "ERROR" && body["message"] == "Integration test error" && body["service"] == "integration-svc"
    }).to have_been_made.once
  end

  it "forwards logger output" do
    configure_opentrace!(service: "logger-svc")
    io = StringIO.new
    logger = OpenTrace::Logger.new(::Logger.new(io))
    logger.warn("Logger integration test")
    OpenTrace.shutdown(timeout: 5)
    expect(io.string).to include("Logger integration test")
    expect(a_request(:post, "https://opentrace.test/api/logs").with { |req|
      body = parse_log_body(req)
      body["level"] == "WARN" && body["message"] == "Logger integration test"
    }).to have_been_made
  end

  it "delivers multiple rapid logs" do
    received = []
    stub_request(:post, "https://opentrace.test/api/logs").to_return { |req|
      received.concat(JSON.parse(req.body)); { status: 201, body: "{\"count\":1}" }
    }
    configure_opentrace!
    20.times { |i| OpenTrace.log("INFO", "rapid-#{i}") }
    OpenTrace.shutdown(timeout: 5)
    expect(received.size).to eq(20)
  end

  it "stops sending after disable!" do
    configure_opentrace!
    OpenTrace.log("INFO", "before disable")
    sleep 0.3
    OpenTrace.disable!
    WebMock.reset!
    stub_request(:post, "https://opentrace.test/api/logs").to_return(status: 201, body: '{"count":1}')
    OpenTrace.log("INFO", "after disable")
    sleep 0.3
    expect(a_request(:post, "https://opentrace.test/api/logs").with { |req|
      parse_log_body(req)["message"] == "after disable"
    }).not_to have_been_made
  end

  it "silently drops logs when server returns errors" do
    stub_request(:post, "https://opentrace.test/api/logs").to_return(status: 503, body: "Service Unavailable")
    configure_opentrace!
    expect { 5.times { OpenTrace.log("ERROR", "server down") }; OpenTrace.shutdown(timeout: 5) }.not_to raise_error
  end

  it "context resolution works" do
    configure_opentrace!(context: -> { { user_id: 99 } })
    ctx = OpenTrace.send(:resolve_context_raw)
    ctx = ctx.is_a?(Hash) ? ctx : {}
    expect(ctx[:user_id]).to eq(99)
  end

  it "switches to new endpoint after reconfigure" do
    configure_opentrace!
    OpenTrace.log("INFO", "to old endpoint")
    OpenTrace.shutdown(timeout: 3)
    new_stub = stub_request(:post, "https://new-server.test/api/logs").to_return(status: 201, body: '{"count":1}')
    OpenTrace.configure { |c| c.endpoint = "https://new-server.test"; c.api_key = "new-key"; c.service = "new-svc"; c.environment = "test" }
    OpenTrace.log("INFO", "to new endpoint")
    OpenTrace.shutdown(timeout: 3)
    expect(new_stub).to have_been_requested.once
  end
end
