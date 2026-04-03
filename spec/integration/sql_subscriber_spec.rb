# frozen_string_literal: true
require "stringio"
require "securerandom"
require_relative "rails_spec_helper"

RSpec.describe "SQL subscriber" do
  before do
    configure_opentrace!(sql_logging: true, min_level: :debug)
    stub_request(:post, "https://opentrace.test/api/logs").to_return(status: 201, body: '{"count":1}')
    ActiveSupport::Notifications.reset!
    Rails.logger = ::Logger.new(StringIO.new)
    app = Rails::Application.new
    app.config.logger = ::Logger.new(StringIO.new)
    OpenTrace::Railtie.initializer_blocks.each { |block| block.call(app) }
    OpenTrace::Railtie.config.after_initialize_blocks.each { |block| block.call(app) }
  end

  def instrument_sql(payload)
    ActiveSupport::Notifications.instrument("sql.active_record", payload) {}
  end

  it "captures SQL queries with expected fields" do
    instrument_sql(name: "User Load", sql: 'SELECT "users".* FROM "users" WHERE "users"."id" = $1', cached: false)
    sleep 0.5
    expect(a_request(:post, "https://opentrace.test/api/logs").with { |req|
      body = parse_log_body(req)
      body["metadata"]["sql_name"] == "User Load" && body["metadata"]["sql"]&.include?("SELECT")
    }).to have_been_made
  end

  it "extracts table name from SELECT" do
    instrument_sql(name: "User Load", sql: "SELECT * FROM users WHERE id = 1")
    sleep 0.5
    expect(a_request(:post, "https://opentrace.test/api/logs").with { |req|
      parse_log_body(req)["metadata"]["sql_table"] == "users"
    }).to have_been_made
  end

  it "logs at DEBUG level" do
    instrument_sql(name: "User Load", sql: "SELECT * FROM users WHERE id = 1")
    sleep 0.5
    expect(a_request(:post, "https://opentrace.test/api/logs").with { |req|
      parse_log_body(req)["level"] == "DEBUG"
    }).to have_been_made
  end

  it "skips SCHEMA queries" do
    WebMock.reset!
    stub_request(:post, "https://opentrace.test/api/logs").to_return(status: 201, body: '{"count":1}')
    instrument_sql(name: "SCHEMA", sql: "SELECT version FROM schema_migrations")
    sleep 0.5
    expect(a_request(:post, "https://opentrace.test/api/logs").with { |req|
      parse_log_body(req)["metadata"]&.key?("sql_name")
    }).not_to have_been_made
  end

  it "truncates long SQL to 1000 chars" do
    long_sql = "SELECT * FROM users WHERE name IN (#{Array.new(500) { |i| "'user_#{i}'" }.join(", ")})"
    instrument_sql(name: "User Load", sql: long_sql)
    sleep 0.5
    expect(a_request(:post, "https://opentrace.test/api/logs").with { |req|
      sql = parse_log_body(req)["metadata"]["sql"]
      sql && sql.length <= 1004 && sql.end_with?("...")
    }).to have_been_made
  end

  it "does not forward SQL logs when sql_logging is false" do
    configure_opentrace!(sql_logging: false)
    ActiveSupport::Notifications.reset!
    app = Rails::Application.new
    app.config.logger = ::Logger.new(StringIO.new)
    OpenTrace::Railtie.initializer_blocks.each { |block| block.call(app) }
    OpenTrace::Railtie.config.after_initialize_blocks.each { |block| block.call(app) }
    WebMock.reset!
    stub_request(:post, "https://opentrace.test/api/logs").to_return(status: 201, body: '{"count":1}')
    instrument_sql(name: "User Load", sql: "SELECT * FROM users WHERE id = 1")
    sleep 0.5
    expect(a_request(:post, "https://opentrace.test/api/logs").with { |req|
      parse_log_body(req)["metadata"]&.key?("sql_name")
    }).not_to have_been_made
  end

  it "swallows errors without crashing" do
    expect { instrument_sql(name: nil, sql: nil); sleep 0.3 }.not_to raise_error
  end
end
