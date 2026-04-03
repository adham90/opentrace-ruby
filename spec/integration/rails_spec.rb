# frozen_string_literal: true
require "stringio"
require "securerandom"
require_relative "rails_spec_helper"

RSpec.describe "Rails integration" do
  before do
    configure_opentrace!
    stub_request(:post, "https://opentrace.test/api/logs").to_return(status: 201, body: '{"count":1}')
    ActiveSupport::Notifications.reset!
  end

  def run_after_initialize(app)
    OpenTrace::Railtie.initializer_blocks.each { |block| block.call(app) }
    OpenTrace::Railtie.config.after_initialize_blocks.each { |block| block.call(app) }
  end

  describe "OpenTrace::Railtie" do
    it("is defined") { expect(defined?(OpenTrace::Railtie)).to be_truthy }
    it("registers after_initialize") { expect(OpenTrace::Railtie.config.after_initialize_blocks).not_to be_empty }
  end

  describe "Rails 7.1+ BroadcastLogger" do
    before { configure_opentrace!(log_forwarding: true) }
    it "registers LogForwarder" do
      app = Rails::Application.new
      bl = BroadcastLoggerStub.new(::Logger.new(StringIO.new))
      Rails.logger = bl
      run_after_initialize(app)
      expect(bl.broadcasts.first).to be_a(OpenTrace::LogForwarder)
    end
    it "skips when disabled" do
      OpenTrace.disable!
      app = Rails::Application.new
      bl = BroadcastLoggerStub.new(::Logger.new(StringIO.new))
      Rails.logger = bl
      run_after_initialize(app)
      expect(bl.broadcasts).to be_empty
    end
  end

  describe "pre-7.1 logger wrapping" do
    before { configure_opentrace!(log_forwarding: true); Rails.logger = ::Logger.new(StringIO.new) }
    it "wraps with OpenTrace::Logger" do
      app = Rails::Application.new
      app.config.logger = ::Logger.new(StringIO.new)
      run_after_initialize(app)
      expect(app.config.logger).to be_a(OpenTrace::Logger)
    end
  end

  describe "request notification subscriber (buffer-based)" do
    let(:buffer) { OpenTrace::RequestBuffer.new }
    before do
      Rails.logger = ::Logger.new(StringIO.new)
      app = Rails::Application.new
      app.config.logger = ::Logger.new(StringIO.new)
      run_after_initialize(app)
      buffer.id = "test-rails-001"
      buffer.started_at = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      Fiber[:opentrace_buffer] = buffer
    end
    after { Fiber[:opentrace_buffer] = nil }

    it "populates controller, action, status" do
      ActiveSupport::Notifications.instrument("process_action.action_controller",
        controller: "UsersController", action: "show", method: "GET", path: "/users/42", status: 200) {}
      expect(buffer.controller).to eq("UsersController")
      expect(buffer.action).to eq("show")
      expect(buffer.response_status).to eq(200)
    end

    it "captures exception info" do
      error = RuntimeError.new("Not found")
      error.set_backtrace(["app/controllers/orders_controller.rb:10"])
      ActiveSupport::Notifications.instrument("process_action.action_controller",
        controller: "OrdersController", action: "show", method: "GET", path: "/orders/99",
        status: 404, exception_object: error) {}
      expect(buffer.logs.size).to eq(1)
      expect(buffer.logs.first[:level]).to eq("ERROR")
      expect(buffer.logs.first[:metadata][:exception_class]).to eq("RuntimeError")
    end

    it "captures params on 500 errors" do
      req_stub = Struct.new(:filtered_parameters).new({"controller" => "o", "action" => "c", "order" => {"id" => 1}})
      ctrl = Object.new; ctrl.define_singleton_method(:request) { req_stub }
      ActiveSupport::Notifications.instrument("process_action.action_controller",
        controller: "OrdersController", action: "create", method: "POST", path: "/orders",
        status: 500, controller_instance: ctrl) {}
      expect(buffer.request_params).to eq({"order" => {"id" => 1}})
    end

    it "does not capture params on success without detailed_request_log" do
      req_stub = Struct.new(:filtered_parameters).new({"controller" => "o", "action" => "c", "data" => "x"})
      ctrl = Object.new; ctrl.define_singleton_method(:request) { req_stub }
      ActiveSupport::Notifications.instrument("process_action.action_controller",
        controller: "OrdersController", action: "create", method: "POST", path: "/orders",
        status: 200, controller_instance: ctrl) {}
      expect(buffer.request_params).to be_nil
    end

    it "does nothing when buffer is nil" do
      Fiber[:opentrace_buffer] = nil
      expect {
        ActiveSupport::Notifications.instrument("process_action.action_controller",
          controller: "UsersController", action: "show", method: "GET", path: "/users/42", status: 200) {}
      }.not_to raise_error
    end
  end
end
