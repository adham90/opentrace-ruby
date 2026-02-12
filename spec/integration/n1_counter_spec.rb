# frozen_string_literal: true

require "stringio"
require "securerandom"

# Load Rails stubs
require_relative "rails_spec_helper"

RSpec.describe "N+1 query counter" do
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

  def simulate_request_with_sql(sql_count:)
    # Set up Fiber-locals as middleware would
    Fiber[:opentrace_sql_count] = 0
    Fiber[:opentrace_sql_total_ms] = 0.0

    # Fire SQL notifications
    sql_count.times do
      ActiveSupport::Notifications.instrument("sql.active_record", {
        name: "User Load",
        sql: "SELECT * FROM users WHERE id = 1",
        cached: false
      }) { sleep 0.001 }
    end

    # Fire controller notification
    headers_env = { "action_dispatch.request_id" => "req-n1-test" }
    headers = Struct.new(:env).new(headers_env)
    ActiveSupport::Notifications.instrument("process_action.action_controller", {
      controller: "UsersController",
      action: "index",
      method: "GET",
      path: "/users",
      status: 200,
      headers: headers
    }) {}
  ensure
    Fiber[:opentrace_sql_count] = nil
    Fiber[:opentrace_sql_total_ms] = nil
  end

  it "includes sql_query_count in controller log" do
    simulate_request_with_sql(sql_count: 5)
    sleep 0.5

    expect(
      a_request(:post, "https://opentrace.test/api/logs")
        .with { |req|
          body = JSON.parse(req.body)
          controller_log = body.find { |l| l["message"]&.include?("GET /users") }
          controller_log && controller_log["metadata"]["sql_query_count"] == 5
        }
    ).to have_been_made
  end

  it "includes sql_total_ms in controller log" do
    simulate_request_with_sql(sql_count: 3)
    sleep 0.5

    expect(
      a_request(:post, "https://opentrace.test/api/logs")
        .with { |req|
          body = JSON.parse(req.body)
          controller_log = body.find { |l| l["message"]&.include?("GET /users") }
          controller_log && controller_log["metadata"]["sql_total_ms"].is_a?(Numeric)
        }
    ).to have_been_made
  end

  it "sets n_plus_one_warning when count exceeds 20" do
    simulate_request_with_sql(sql_count: 25)
    sleep 0.5

    expect(
      a_request(:post, "https://opentrace.test/api/logs")
        .with { |req|
          body = JSON.parse(req.body)
          controller_log = body.find { |l| l["message"]&.include?("GET /users") }
          controller_log &&
            controller_log["metadata"]["sql_query_count"] == 25 &&
            controller_log["metadata"]["n_plus_one_warning"] == true
        }
    ).to have_been_made
  end

  it "does not set n_plus_one_warning when count is low" do
    simulate_request_with_sql(sql_count: 3)
    sleep 0.5

    expect(
      a_request(:post, "https://opentrace.test/api/logs")
        .with { |req|
          body = JSON.parse(req.body)
          controller_log = body.find { |l| l["message"]&.include?("GET /users") }
          controller_log && controller_log["metadata"]["n_plus_one_warning"].nil?
        }
    ).to have_been_made
  end

  it "resets counters between requests (Fiber-local isolation)" do
    simulate_request_with_sql(sql_count: 10)
    # Fiber-locals should be nil now
    expect(Fiber[:opentrace_sql_count]).to be_nil
    expect(Fiber[:opentrace_sql_total_ms]).to be_nil
  end
end
