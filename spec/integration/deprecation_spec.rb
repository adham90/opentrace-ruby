# frozen_string_literal: true

require "stringio"
require "securerandom"

require_relative "rails_spec_helper"

RSpec.describe "Deprecation warning subscriber" do
  before do
    configure_opentrace!
    stub_request(:post, "https://opentrace.test/api/logs")
      .to_return(status: 201, body: '{"count":1}')
    ActiveSupport::Notifications.reset!

    Rails.logger = ::Logger.new(StringIO.new)
    app = Rails::Application.new
    app.config.logger = ::Logger.new(StringIO.new)
    OpenTrace::Railtie.initializer_blocks.each { |block| block.call(app) }
    OpenTrace::Railtie.config.after_initialize_blocks.each { |block| block.call(app) }
  end

  it "captures deprecation message and callsite" do
    callstack = [
      "app/models/concerns/timezone_aware.rb:14:in `set_timezone'",
      "app/controllers/application_controller.rb:5:in `before_action'"
    ]

    ActiveSupport::Notifications.instrument("deprecation.rails", {
      message: "ActiveRecord::Base.default_timezone is deprecated",
      callstack: callstack
    })
    sleep 0.5

    expect(
      a_request(:post, "https://opentrace.test/api/logs")
        .with { |req|
          body = parse_log_body(req)
          body["level"] == "WARN" &&
            body["message"].include?("DEPRECATION:") &&
            body["metadata"]["deprecation_message"].include?("default_timezone") &&
            body["metadata"]["deprecation_callsite"].include?("timezone_aware.rb")
        }
    ).to have_been_made
  end

  it "includes request_id when in web context" do
    OpenTrace.current_request_id = "req-deprecation-test"

    ActiveSupport::Notifications.instrument("deprecation.rails", {
      message: "Some deprecated API",
      callstack: ["app/models/user.rb:10"]
    })
    sleep 0.5

    expect(
      a_request(:post, "https://opentrace.test/api/logs")
        .with { |req|
          body = parse_log_body(req)
          body["metadata"]["request_id"] == "req-deprecation-test"
        }
    ).to have_been_made
  ensure
    OpenTrace.current_request_id = nil
  end

  it "handles nil callstack gracefully" do
    expect {
      ActiveSupport::Notifications.instrument("deprecation.rails", {
        message: "Some deprecated API",
        callstack: nil
      })
      sleep 0.3
    }.not_to raise_error
  end

  it "truncates long deprecation messages" do
    long_message = "Deprecated: " + "x" * 600

    ActiveSupport::Notifications.instrument("deprecation.rails", {
      message: long_message,
      callstack: ["app/models/user.rb:1"]
    })
    sleep 0.5

    expect(
      a_request(:post, "https://opentrace.test/api/logs")
        .with { |req|
          body = parse_log_body(req)
          body["metadata"]["deprecation_message"].length <= 504 &&
            body["message"].length <= 220
        }
    ).to have_been_made
  end
end
