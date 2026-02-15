# frozen_string_literal: true

require "stringio"
require "securerandom"
require_relative "rails_spec_helper"

RSpec.describe "Rails integration" do
  before do
    configure_opentrace!
    stub_request(:post, "https://opentrace.test/api/logs")
      .to_return(status: 201, body: '{"count":1}')
    ActiveSupport::Notifications.reset!
  end

  # Helper to simulate Rails boot by running initializer + after_initialize blocks
  def run_after_initialize(app)
    OpenTrace::Railtie.initializer_blocks.each { |block| block.call(app) }
    OpenTrace::Railtie.config.after_initialize_blocks.each { |block| block.call(app) }
  end

  describe "OpenTrace::Railtie" do
    it "is defined when Rails is present" do
      expect(defined?(OpenTrace::Railtie)).to be_truthy
    end

    it "registers an after_initialize block" do
      expect(OpenTrace::Railtie.config.after_initialize_blocks).not_to be_empty
    end
  end

  describe "Rails 7.1+ BroadcastLogger integration" do
    before do
      configure_opentrace!(log_forwarding: true)
    end

    it "registers LogForwarder as a broadcast target" do
      app = Rails::Application.new
      broadcast_logger = BroadcastLoggerStub.new(::Logger.new(StringIO.new))
      Rails.logger = broadcast_logger

      run_after_initialize(app)

      expect(broadcast_logger.broadcasts.size).to eq(1)
      expect(broadcast_logger.broadcasts.first).to be_a(OpenTrace::LogForwarder)
    end

    it "does not replace Rails.logger" do
      app = Rails::Application.new
      broadcast_logger = BroadcastLoggerStub.new(::Logger.new(StringIO.new))
      Rails.logger = broadcast_logger

      run_after_initialize(app)

      expect(Rails.logger).to equal(broadcast_logger)
    end

    it "skips broadcast when OpenTrace is disabled" do
      OpenTrace.disable!

      app = Rails::Application.new
      broadcast_logger = BroadcastLoggerStub.new(::Logger.new(StringIO.new))
      Rails.logger = broadcast_logger

      run_after_initialize(app)

      expect(broadcast_logger.broadcasts).to be_empty
    end

    it "skips broadcast when log_forwarding is false" do
      configure_opentrace!(log_forwarding: false)

      app = Rails::Application.new
      broadcast_logger = BroadcastLoggerStub.new(::Logger.new(StringIO.new))
      Rails.logger = broadcast_logger

      run_after_initialize(app)

      expect(broadcast_logger.broadcasts).to be_empty
    end
  end

  describe "pre-7.1 logger wrapping (fallback)" do
    before do
      configure_opentrace!(log_forwarding: true)
      # Use a plain logger without broadcast_to
      Rails.logger = ::Logger.new(StringIO.new)
    end

    it "wraps the app logger with OpenTrace::Logger" do
      app = Rails::Application.new
      io = StringIO.new
      app.config.logger = ::Logger.new(io)

      run_after_initialize(app)

      expect(app.config.logger).to be_a(OpenTrace::Logger)
    end

    it "skips wrapping when OpenTrace is disabled" do
      OpenTrace.disable!

      app = Rails::Application.new
      original_logger = ::Logger.new(StringIO.new)
      app.config.logger = original_logger

      run_after_initialize(app)

      expect(app.config.logger).to eq(original_logger)
    end

    it "preserves the original logger as wrapped_logger" do
      app = Rails::Application.new
      original_logger = ::Logger.new(StringIO.new)
      app.config.logger = original_logger

      run_after_initialize(app)

      expect(app.config.logger.wrapped_logger).to eq(original_logger)
    end

    it "sets Rails.logger to the wrapped logger" do
      app = Rails::Application.new
      app.config.logger = ::Logger.new(StringIO.new)

      run_after_initialize(app)

      expect(Rails.logger).to be_a(OpenTrace::Logger)
    end
  end

  describe "request notification subscriber" do
    before do
      # Use plain logger for notification tests
      Rails.logger = ::Logger.new(StringIO.new)
      app = Rails::Application.new
      app.config.logger = ::Logger.new(StringIO.new)
      run_after_initialize(app)
    end

    it "logs controller actions via ActiveSupport::Notifications" do
      payload = {
        controller: "UsersController",
        action: "show",
        method: "GET",
        path: "/users/42",
        status: 200,
        headers: nil
      }

      ActiveSupport::Notifications.instrument("process_action.action_controller", payload) {}
      sleep 0.5

      expect(
        a_request(:post, "https://opentrace.test/api/logs")
          .with { |req|
            body = parse_log_body(req)
            body["level"] == "INFO" &&
              body["message"].include?("GET /users/42 200") &&
              body["metadata"]["controller"] == "UsersController" &&
              body["metadata"]["action"] == "show"
          }
      ).to have_been_made
    end

    it "logs 5xx responses as ERROR" do
      payload = {
        controller: "OrdersController",
        action: "create",
        method: "POST",
        path: "/orders",
        status: 500,
        headers: nil
      }

      ActiveSupport::Notifications.instrument("process_action.action_controller", payload) {}
      sleep 0.5

      expect(
        a_request(:post, "https://opentrace.test/api/logs")
          .with { |req| parse_log_body(req)["level"] == "ERROR" }
      ).to have_been_made
    end

    it "logs 4xx responses as WARN" do
      payload = {
        controller: "SessionsController",
        action: "create",
        method: "POST",
        path: "/login",
        status: 422,
        headers: nil
      }

      ActiveSupport::Notifications.instrument("process_action.action_controller", payload) {}
      sleep 0.5

      expect(
        a_request(:post, "https://opentrace.test/api/logs")
          .with { |req| parse_log_body(req)["level"] == "WARN" }
      ).to have_been_made
    end

    it "captures user_id from cached context" do
      # Simulate middleware caching context with user_id
      Fiber[:opentrace_cached_context] = { user_id: 42 }

      payload = {
        controller: "ApiController",
        action: "index",
        method: "GET",
        path: "/api/items",
        status: 200,
        headers: nil
      }

      ActiveSupport::Notifications.instrument("process_action.action_controller", payload) {}
      sleep 0.5

      expect(
        a_request(:post, "https://opentrace.test/api/logs")
          .with { |req|
            body = parse_log_body(req)
            body["metadata"]["user_id"] == 42
          }
      ).to have_been_made
    ensure
      Fiber[:opentrace_cached_context] = nil
    end

    it "handles missing cached context gracefully" do
      payload = {
        controller: "HealthController",
        action: "show",
        method: "GET",
        path: "/healthz",
        status: 200,
        headers: nil
      }

      expect {
        ActiveSupport::Notifications.instrument("process_action.action_controller", payload) {}
        sleep 0.3
      }.not_to raise_error
    end

    it "captures exception_class and exception_message" do
      error = RuntimeError.new("Couldn't find Order with id=99")
      error.set_backtrace(["app/controllers/orders_controller.rb:10:in `show'", "gems/actionpack/lib/action.rb:42"])

      payload = {
        controller: "OrdersController",
        action: "show",
        method: "GET",
        path: "/orders/99",
        status: 404,
        headers: nil,
        exception: ["ActiveRecord::RecordNotFound", "Couldn't find Order with id=99"],
        exception_object: error
      }

      ActiveSupport::Notifications.instrument("process_action.action_controller", payload) {}
      sleep 0.5

      expect(
        a_request(:post, "https://opentrace.test/api/logs")
          .with { |req|
            body = parse_log_body(req)
            body["level"] == "ERROR" &&
              body["exception_class"] == "ActiveRecord::RecordNotFound" &&
              body["metadata"]["exception_message"] == "Couldn't find Order with id=99" &&
              body["metadata"]["backtrace"].is_a?(Array)
          }
      ).to have_been_made
    end

    it "logs ERROR when exception present even with 200 status" do
      payload = {
        controller: "OrdersController",
        action: "create",
        method: "POST",
        path: "/orders",
        status: 200,
        headers: nil,
        exception: ["SomeError", "rescued but still logged"]
      }

      ActiveSupport::Notifications.instrument("process_action.action_controller", payload) {}
      sleep 0.5

      expect(
        a_request(:post, "https://opentrace.test/api/logs")
          .with { |req| parse_log_body(req)["level"] == "ERROR" }
      ).to have_been_made
    end

    it "cleans backtrace by filtering gem lines" do
      error = RuntimeError.new("boom")
      error.set_backtrace([
        "app/models/order.rb:34:in `create_line_item'",
        "/gems/activerecord-7.0/lib/ar.rb:100:in `save'",
        "app/controllers/orders_controller.rb:18:in `create'"
      ])

      payload = {
        controller: "OrdersController",
        action: "create",
        method: "POST",
        path: "/orders",
        status: 500,
        headers: nil,
        exception: ["RuntimeError", "boom"],
        exception_object: error
      }

      ActiveSupport::Notifications.instrument("process_action.action_controller", payload) {}
      sleep 0.5

      expect(
        a_request(:post, "https://opentrace.test/api/logs")
          .with { |req|
            bt = parse_log_body(req)["metadata"]["backtrace"]
            bt.length == 2 && bt.none? { |l| l.include?("/gems/") }
          }
      ).to have_been_made
    end

    it "captures filtered request params when detailed_request_log is enabled" do
      # Re-initialize with detailed_request_log
      ActiveSupport::Notifications.reset!
      configure_opentrace!(detailed_request_log: true)
      Rails.logger = ::Logger.new(StringIO.new)
      app = Rails::Application.new
      app.config.logger = ::Logger.new(StringIO.new)
      run_after_initialize(app)

      request_stub = Struct.new(:filtered_parameters).new(
        { "controller" => "orders", "action" => "create", "order" => { "product_id" => 99 } }
      )
      controller_stub = Object.new
      controller_stub.define_singleton_method(:request) { request_stub }

      payload = {
        controller: "OrdersController",
        action: "create",
        method: "POST",
        path: "/orders",
        status: 201,
        headers: nil,
        controller_instance: controller_stub
      }

      ActiveSupport::Notifications.instrument("process_action.action_controller", payload) {}
      sleep 0.5

      expect(
        a_request(:post, "https://opentrace.test/api/logs")
          .with { |req|
            params = parse_log_body(req)["metadata"]["params"]
            params == { "order" => { "product_id" => 99 } }
          }
      ).to have_been_made
    end

    it "strips controller and action from params" do
      ActiveSupport::Notifications.reset!
      configure_opentrace!(detailed_request_log: true)
      Rails.logger = ::Logger.new(StringIO.new)
      app = Rails::Application.new
      app.config.logger = ::Logger.new(StringIO.new)
      run_after_initialize(app)

      request_stub = Struct.new(:filtered_parameters).new(
        { "controller" => "orders", "action" => "create", "name" => "test" }
      )
      controller_stub = Object.new
      controller_stub.define_singleton_method(:request) { request_stub }

      payload = {
        controller: "OrdersController",
        action: "create",
        method: "POST",
        path: "/orders",
        status: 201,
        headers: nil,
        controller_instance: controller_stub
      }

      ActiveSupport::Notifications.instrument("process_action.action_controller", payload) {}
      sleep 0.5

      expect(
        a_request(:post, "https://opentrace.test/api/logs")
          .with { |req|
            params = parse_log_body(req)["metadata"]["params"]
            params.is_a?(Hash) && !params.key?("controller") && !params.key?("action")
          }
      ).to have_been_made
    end

    it "truncates oversized params" do
      ActiveSupport::Notifications.reset!
      configure_opentrace!(detailed_request_log: true)
      Rails.logger = ::Logger.new(StringIO.new)
      app = Rails::Application.new
      app.config.logger = ::Logger.new(StringIO.new)
      run_after_initialize(app)

      large_value = "x" * 3000
      request_stub = Struct.new(:filtered_parameters).new(
        { "data" => large_value }
      )
      controller_stub = Object.new
      controller_stub.define_singleton_method(:request) { request_stub }

      payload = {
        controller: "OrdersController",
        action: "create",
        method: "POST",
        path: "/orders",
        status: 201,
        headers: nil,
        controller_instance: controller_stub
      }

      ActiveSupport::Notifications.instrument("process_action.action_controller", payload) {}
      sleep 0.5

      expect(
        a_request(:post, "https://opentrace.test/api/logs")
          .with { |req|
            params = parse_log_body(req)["metadata"]["params"]
            params.is_a?(Hash) && params["_truncated"] == true
          }
      ).to have_been_made
    end

    it "does not log requests to ignored paths (string match)" do
      OpenTrace.config.ignore_paths = ["/health", "/up"]

      WebMock.reset!
      stub_request(:post, "https://opentrace.test/api/logs")
        .to_return(status: 201, body: '{"count":1}')

      payload = {
        controller: "HealthController",
        action: "show",
        method: "GET",
        path: "/health",
        status: 200,
        headers: nil
      }

      ActiveSupport::Notifications.instrument("process_action.action_controller", payload) {}
      sleep 0.3

      expect(a_request(:post, "https://opentrace.test/api/logs")).not_to have_been_made
    end

    it "does not log requests to ignored paths (regexp match)" do
      OpenTrace.config.ignore_paths = [%r{\A/assets/}]

      WebMock.reset!
      stub_request(:post, "https://opentrace.test/api/logs")
        .to_return(status: 201, body: '{"count":1}')

      payload = {
        controller: "AssetsController",
        action: "show",
        method: "GET",
        path: "/assets/logo.png",
        status: 200,
        headers: nil
      }

      ActiveSupport::Notifications.instrument("process_action.action_controller", payload) {}
      sleep 0.3

      expect(a_request(:post, "https://opentrace.test/api/logs")).not_to have_been_made
    end

    it "still logs requests to non-ignored paths" do
      OpenTrace.config.ignore_paths = ["/health", "/up"]

      payload = {
        controller: "UsersController",
        action: "index",
        method: "GET",
        path: "/users",
        status: 200,
        headers: nil
      }

      ActiveSupport::Notifications.instrument("process_action.action_controller", payload) {}
      sleep 0.5

      expect(
        a_request(:post, "https://opentrace.test/api/logs")
          .with { |req| parse_log_body(req)["message"].include?("GET /users 200") }
      ).to have_been_made
    end

    it "does not log when OpenTrace is disabled" do
      OpenTrace.disable!

      WebMock.reset!
      stub_request(:post, "https://opentrace.test/api/logs")
        .to_return(status: 201, body: '{"count":1}')

      payload = {
        controller: "PagesController",
        action: "home",
        method: "GET",
        path: "/",
        status: 200,
        headers: nil
      }

      ActiveSupport::Notifications.instrument("process_action.action_controller", payload) {}
      sleep 0.3

      expect(a_request(:post, "https://opentrace.test/api/logs")).not_to have_been_made
    end
  end
end
