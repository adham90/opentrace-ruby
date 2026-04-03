# frozen_string_literal: true

require "stringio"
require "securerandom"
require_relative "rails_spec_helper"

RSpec.describe "N+1 query counter (buffer-based)" do
  let(:buffer) { OpenTrace::RequestBuffer.new }

  before do
    configure_opentrace!
    stub_request(:post, "https://opentrace.test/api/logs").to_return(status: 201, body: '{"count":1}')
    ActiveSupport::Notifications.reset!
    Rails.logger = ::Logger.new(StringIO.new)
    app = Rails::Application.new
    app.config.logger = ::Logger.new(StringIO.new)
    OpenTrace::Railtie.initializer_blocks.each { |block| block.call(app) }
    OpenTrace::Railtie.config.after_initialize_blocks.each { |block| block.call(app) }
    buffer.id = "test-n1-001"
    buffer.started_at = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    Fiber[:opentrace_buffer] = buffer
  end

  after { Fiber[:opentrace_buffer] = nil }

  def fire_sql(count)
    count.times do
      ActiveSupport::Notifications.instrument("sql.active_record",
        name: "User Load", sql: "SELECT * FROM users WHERE id = 1", cached: false) { sleep 0.001 }
    end
  end

  it("tracks SQL query count") { fire_sql(5); expect(buffer.sql_captures.size).to eq(5) }
  it("tracks SQL durations")   { fire_sql(3); expect(buffer.sql_captures.sum { |c| c[:duration_ms] }).to be > 0 }
  it("detects N+1 pattern")    { fire_sql(25); expect(buffer.sql_captures.map { |c| c[:fingerprint] }.uniq.size).to eq(1) }

  it "populates controller/action from process_action" do
    fire_sql(5)
    ActiveSupport::Notifications.instrument("process_action.action_controller",
      controller: "UsersController", action: "index", method: "GET", path: "/users", status: 200) {}
    expect(buffer.controller).to eq("UsersController")
    expect(buffer.action).to eq("index")
  end
end
