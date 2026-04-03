# frozen_string_literal: true
require "stringio"
require "securerandom"
require_relative "rails_spec_helper"

RSpec.describe "Request headers in process_action subscriber" do
  let(:buffer) { OpenTrace::RequestBuffer.new }
  before do
    configure_opentrace!(detailed_request_log: true)
    stub_request(:post, "https://opentrace.test/api/logs").to_return(status: 201, body: '{"count":1}')
    ActiveSupport::Notifications.reset!
    Rails.logger = ::Logger.new(StringIO.new)
    app = Rails::Application.new
    app.config.logger = ::Logger.new(StringIO.new)
    OpenTrace::Railtie.initializer_blocks.each { |block| block.call(app) }
    OpenTrace::Railtie.config.after_initialize_blocks.each { |block| block.call(app) }
    buffer.id = "test-headers-001"
    buffer.started_at = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    Fiber[:opentrace_buffer] = buffer
  end
  after { Fiber[:opentrace_buffer] = nil }

  it "populates buffer without crashing when headers are present" do
    headers = Struct.new(:env).new({"action_dispatch.request_id" => "req-headers-test"})
    expect {
      ActiveSupport::Notifications.instrument("process_action.action_controller",
        controller: "ApiController", action: "create", method: "POST", path: "/api/data", status: 200, headers: headers) {}
    }.not_to raise_error
    expect(buffer.controller).to eq("ApiController")
  end

  it "handles nil headers gracefully" do
    expect {
      ActiveSupport::Notifications.instrument("process_action.action_controller",
        controller: "ApiController", action: "create", method: "POST", path: "/api/data", status: 200, headers: nil) {}
    }.not_to raise_error
  end
end
