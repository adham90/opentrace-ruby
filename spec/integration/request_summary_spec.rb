# frozen_string_literal: true
require "stringio"
require "securerandom"
require_relative "rails_spec_helper"

RSpec.describe "Request summary via RequestBuffer" do
  let(:buffer) { OpenTrace::RequestBuffer.new }
  before do
    configure_opentrace!(view_tracking: true, cache_tracking: true, timeline: true)
    stub_request(:post, "https://opentrace.test/api/logs").to_return(status: 201, body: '{"count":1}')
    ActiveSupport::Notifications.reset!
    Rails.logger = ::Logger.new(StringIO.new)
    app = Rails::Application.new
    app.config.logger = ::Logger.new(StringIO.new)
    OpenTrace::Railtie.initializer_blocks.each { |block| block.call(app) }
    OpenTrace::Railtie.config.after_initialize_blocks.each { |block| block.call(app) }
    buffer.id = "test-summary-001"
    buffer.started_at = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    Fiber[:opentrace_buffer] = buffer
  end
  after { Fiber[:opentrace_buffer] = nil }

  it "includes SQL captures from buffer" do
    3.times { ActiveSupport::Notifications.instrument("sql.active_record", name: "User Load", sql: "SELECT * FROM users WHERE id = 1", cached: false) { sleep 0.001 } }
    ActiveSupport::Notifications.instrument("process_action.action_controller", controller: "OrdersController", action: "show", method: "GET", path: "/orders/1", status: 200) {}
    expect(buffer.sql_captures.size).to eq(3)
    expect(buffer.controller).to eq("OrdersController")
  end

  it "includes view render data in timeline" do
    ActiveSupport::Notifications.instrument("render_template.action_view", identifier: "/app/views/orders/show.html.erb") { sleep 0.001 }
    3.times { ActiveSupport::Notifications.instrument("render_partial.action_view", identifier: "/app/views/orders/_item.html.erb") { sleep 0.001 } }
    expect(buffer.timeline.select { |e| e[:type] == :view }.size).to eq(4)
  end

  it "shortens view template paths" do
    ActiveSupport::Notifications.instrument("render_template.action_view", identifier: "/Users/deploy/app/views/orders/show.html.erb") { sleep 0.001 }
    expect(buffer.timeline.first[:name]).to eq("orders/show.html.erb")
  end

  it "includes cache operations in timeline" do
    ActiveSupport::Notifications.instrument("cache_read.active_support", hit: true) { sleep 0.001 }
    ActiveSupport::Notifications.instrument("cache_write.active_support", {}) { sleep 0.001 }
    expect(buffer.timeline.select { |e| e[:type] == :cache }.size).to eq(2)
  end

  it "includes mixed timeline events" do
    ActiveSupport::Notifications.instrument("sql.active_record", name: "User Load", sql: "SELECT * FROM users", cached: false) { sleep 0.001 }
    ActiveSupport::Notifications.instrument("render_template.action_view", identifier: "/app/views/orders/show.html.erb") { sleep 0.001 }
    ActiveSupport::Notifications.instrument("cache_read.active_support", hit: true) { sleep 0.001 }
    types = buffer.timeline.map { |e| e[:type] }
    expect(types).to include(:sql, :view, :cache)
  end

  it "does not record when buffer is nil" do
    Fiber[:opentrace_buffer] = nil
    ActiveSupport::Notifications.instrument("render_template.action_view", identifier: "/app/views/orders/show.html.erb") { sleep 0.001 }
    ActiveSupport::Notifications.instrument("cache_read.active_support", hit: true) { sleep 0.001 }
    expect(buffer.timeline).to be_empty
  end

  it "generates a complete document" do
    3.times { ActiveSupport::Notifications.instrument("sql.active_record", name: "User Load", sql: "SELECT * FROM users WHERE id = 1", cached: false) { sleep 0.001 } }
    ActiveSupport::Notifications.instrument("process_action.action_controller", controller: "OrdersController", action: "show", method: "GET", path: "/orders/1", status: 200) {}
    doc = buffer.to_document(capture_level: :standard)
    expect(doc[:controller]).to eq("OrdersController")
    expect(doc[:sql].size).to eq(3)
  end
end
