# frozen_string_literal: true

require "stringio"
require "securerandom"

# Load Rails stubs from rails_spec (shared stubs)
require_relative "rails_spec_helper"

RSpec.describe "SQL subscriber" do
  before do
    configure_opentrace!
    stub_request(:post, "https://opentrace.test/api/logs")
      .to_return(status: 201, body: '{"count":1}')
    ActiveSupport::Notifications.reset!

    # Initialize the Railtie (registers subscribers)
    Rails.logger = ::Logger.new(StringIO.new)
    app = Rails::Application.new
    app.config.logger = ::Logger.new(StringIO.new)
    OpenTrace::Railtie.initializer_blocks.each { |block| block.call(app) }
    OpenTrace::Railtie.config.after_initialize_blocks.each { |block| block.call(app) }
  end

  def instrument_sql(payload)
    start_time = Time.now
    sleep 0.001 # small duration
    end_time = Time.now

    # Allow overriding start/end for duration control
    if payload.delete(:_duration_ms)
      duration_s = payload.delete(:_duration_ms) / 1000.0
      end_time = start_time + duration_s
    end

    ActiveSupport::Notifications.instrument("sql.active_record", payload) {}
  end

  it "captures SQL queries with expected fields" do
    instrument_sql(
      name: "User Load",
      sql: "SELECT \"users\".* FROM \"users\" WHERE \"users\".\"id\" = $1",
      cached: false
    )
    sleep 0.5

    expect(
      a_request(:post, "https://opentrace.test/api/logs")
        .with { |req|
          body = parse_log_body(req)
          body["metadata"]["sql_name"] == "User Load" &&
            body["metadata"]["sql"].include?("SELECT") &&
            body["metadata"]["sql_duration_ms"].is_a?(Numeric) &&
            body["metadata"]["sql_cached"] == false
        }
    ).to have_been_made
  end

  it "extracts table name from SELECT query" do
    instrument_sql(
      name: "User Load",
      sql: "SELECT * FROM users WHERE id = 1"
    )
    sleep 0.5

    expect(
      a_request(:post, "https://opentrace.test/api/logs")
        .with { |req|
          parse_log_body(req)["metadata"]["sql_table"] == "users"
        }
    ).to have_been_made
  end

  it "extracts table name from INSERT query" do
    instrument_sql(
      name: "Order Create",
      sql: "INSERT INTO orders (user_id) VALUES ($1)"
    )
    sleep 0.5

    expect(
      a_request(:post, "https://opentrace.test/api/logs")
        .with { |req|
          parse_log_body(req)["metadata"]["sql_table"] == "orders"
        }
    ).to have_been_made
  end

  it "logs at DEBUG level for normal queries" do
    instrument_sql(
      name: "User Load",
      sql: "SELECT * FROM users WHERE id = 1"
    )
    sleep 0.5

    expect(
      a_request(:post, "https://opentrace.test/api/logs")
        .with { |req| parse_log_body(req)["level"] == "DEBUG" }
    ).to have_been_made
  end

  it "skips SCHEMA queries" do
    WebMock.reset!
    stub_request(:post, "https://opentrace.test/api/logs")
      .to_return(status: 201, body: '{"count":1}')

    instrument_sql(
      name: "SCHEMA",
      sql: "SELECT version FROM schema_migrations"
    )
    sleep 0.5

    expect(
      a_request(:post, "https://opentrace.test/api/logs")
        .with { |req| parse_log_body(req)["metadata"]&.key?("sql_name") }
    ).not_to have_been_made
  end

  it "truncates long SQL to 1000 chars" do
    long_sql = "SELECT * FROM users WHERE name IN (#{Array.new(500) { |i| "'user_#{i}'" }.join(", ")})"

    instrument_sql(
      name: "User Load",
      sql: long_sql
    )
    sleep 0.5

    expect(
      a_request(:post, "https://opentrace.test/api/logs")
        .with { |req|
          sql = parse_log_body(req)["metadata"]["sql"]
          sql.length <= 1004 && sql.end_with?("...")
        }
    ).to have_been_made
  end

  it "respects sql_duration_threshold_ms" do
    OpenTrace.config.sql_duration_threshold_ms = 100.0

    WebMock.reset!
    stub_request(:post, "https://opentrace.test/api/logs")
      .to_return(status: 201, body: '{"count":1}')

    # Re-initialize to pick up new config
    ActiveSupport::Notifications.reset!
    app = Rails::Application.new
    app.config.logger = ::Logger.new(StringIO.new)
    OpenTrace::Railtie.initializer_blocks.each { |block| block.call(app) }
    OpenTrace::Railtie.config.after_initialize_blocks.each { |block| block.call(app) }

    # This will have a very short duration (< 100ms), should be filtered
    instrument_sql(
      name: "User Load",
      sql: "SELECT * FROM users WHERE id = 1"
    )
    sleep 0.5

    expect(
      a_request(:post, "https://opentrace.test/api/logs")
        .with { |req| parse_log_body(req)["metadata"]&.key?("sql_name") }
    ).not_to have_been_made
  end

  it "does not subscribe when sql_logging is false" do
    OpenTrace.config.sql_logging = false

    ActiveSupport::Notifications.reset!
    app = Rails::Application.new
    app.config.logger = ::Logger.new(StringIO.new)
    OpenTrace::Railtie.initializer_blocks.each { |block| block.call(app) }
    OpenTrace::Railtie.config.after_initialize_blocks.each { |block| block.call(app) }

    WebMock.reset!
    stub_request(:post, "https://opentrace.test/api/logs")
      .to_return(status: 201, body: '{"count":1}')

    instrument_sql(
      name: "User Load",
      sql: "SELECT * FROM users WHERE id = 1"
    )
    sleep 0.5

    expect(
      a_request(:post, "https://opentrace.test/api/logs")
        .with { |req| parse_log_body(req)["metadata"]&.key?("sql_name") }
    ).not_to have_been_made
  end

  it "swallows errors without crashing" do
    expect {
      # Instrument with nil sql — could cause issues in processing
      instrument_sql(name: nil, sql: nil)
      sleep 0.3
    }.not_to raise_error
  end

  it "includes request_id from middleware when available" do
    OpenTrace.current_request_id = "req-sql-test"

    instrument_sql(
      name: "Order Load",
      sql: "SELECT * FROM orders WHERE id = 1"
    )
    sleep 0.5

    expect(
      a_request(:post, "https://opentrace.test/api/logs")
        .with { |req|
          parse_log_body(req)["metadata"]["request_id"] == "req-sql-test"
        }
    ).to have_been_made
  ensure
    OpenTrace.current_request_id = nil
  end
end
