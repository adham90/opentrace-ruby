# frozen_string_literal: true

require "stringio"
require "securerandom"

require_relative "rails_spec_helper"

RSpec.describe "Request headers capture" do
  before do
    configure_opentrace!(detailed_request_log: true)
    stub_request(:post, "https://opentrace.test/api/logs")
      .to_return(status: 201, body: '{"count":1}')
    ActiveSupport::Notifications.reset!

    Rails.logger = ::Logger.new(StringIO.new)
    app = Rails::Application.new
    app.config.logger = ::Logger.new(StringIO.new)
    OpenTrace::Railtie.initializer_blocks.each { |block| block.call(app) }
    OpenTrace::Railtie.config.after_initialize_blocks.each { |block| block.call(app) }
  end

  def simulate_request(env_overrides = {})
    env = {
      "action_dispatch.request_id" => "req-headers-test",
      "CONTENT_TYPE" => "application/json",
      "HTTP_ACCEPT" => "application/json",
      "HTTP_USER_AGENT" => "TestClient/1.0",
      "HTTP_REFERER" => "https://example.com/page"
    }.merge(env_overrides)

    headers = Struct.new(:env).new(env)

    ActiveSupport::Notifications.instrument("process_action.action_controller", {
      controller: "ApiController",
      action: "create",
      method: "POST",
      path: "/api/data",
      status: 200,
      headers: headers
    }) {}
  end

  it "captures Content-Type, Accept, User-Agent, Referer" do
    simulate_request
    sleep 0.5

    expect(
      a_request(:post, "https://opentrace.test/api/logs")
        .with { |req|
          body = parse_log_body(req)
          meta = body["metadata"]
          meta["request_content_type"] == "application/json" &&
            meta["request_accept"] == "application/json" &&
            meta["request_user_agent"] == "TestClient/1.0" &&
            meta["request_referer"] == "https://example.com/page"
        }
    ).to have_been_made
  end

  it "truncates long User-Agent to 200 chars" do
    long_ua = "A" * 300
    simulate_request("HTTP_USER_AGENT" => long_ua)
    sleep 0.5

    expect(
      a_request(:post, "https://opentrace.test/api/logs")
        .with { |req|
          body = parse_log_body(req)
          ua = body["metadata"]["request_user_agent"]
          ua.length <= 204 && ua.end_with?("...")
        }
    ).to have_been_made
  end

  it "omits nil headers" do
    simulate_request("HTTP_REFERER" => nil)
    sleep 0.5

    expect(
      a_request(:post, "https://opentrace.test/api/logs")
        .with { |req|
          body = parse_log_body(req)
          !body["metadata"].key?("request_referer")
        }
    ).to have_been_made
  end

  it "handles missing headers gracefully" do
    # headers without env method
    ActiveSupport::Notifications.instrument("process_action.action_controller", {
      controller: "ApiController",
      action: "create",
      method: "POST",
      path: "/api/data",
      status: 200,
      headers: nil
    }) {}
    sleep 0.5

    # Should still send the log without crashing
    expect(
      a_request(:post, "https://opentrace.test/api/logs")
        .with { |req|
          body = parse_log_body(req)
          body["message"].include?("POST /api/data")
        }
    ).to have_been_made
  end
end
