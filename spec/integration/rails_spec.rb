# frozen_string_literal: true

require "stringio"
require "securerandom"

# Minimal Rails stubs so we can test the Railtie behavior
# without requiring the entire Rails framework.
module Rails
  def self.env
    "test"
  end

  def self.logger
    @logger ||= ::Logger.new(StringIO.new)
  end

  def self.logger=(l)
    @logger = l
  end

  class Railtie
    class Configuration
      def after_initialize(&block)
        @after_initialize_blocks ||= []
        @after_initialize_blocks << block
      end

      def after_initialize_blocks
        @after_initialize_blocks || []
      end
    end

    def self.config
      @config ||= Configuration.new
    end
  end

  class Application
    class Configuration
      attr_accessor :logger
    end

    def config
      @config ||= Configuration.new
    end
  end
end

# Stub ActiveSupport::Notifications
module ActiveSupport
  module Notifications
    class Event
      attr_reader :payload, :duration

      def initialize(*args)
        @name, @start, @finish, @id, @payload = args
        @duration = (@finish && @start) ? (@finish - @start) * 1000 : 0.0
      end
    end

    @subscribers = {}

    def self.subscribe(event_name, &block)
      @subscribers[event_name] = block
    end

    def self.instrument(event_name, payload = {})
      start_time = Time.now
      result = yield if block_given?
      end_time = Time.now

      if @subscribers[event_name]
        @subscribers[event_name].call(
          event_name, start_time, end_time, SecureRandom.hex(4), payload
        )
      end

      result
    end

    def self.reset!
      @subscribers = {}
    end
  end
end

# Minimal BroadcastLogger stub for Rails 7.1+ testing
class BroadcastLoggerStub
  attr_reader :broadcasts

  def initialize(primary_logger)
    @primary = primary_logger
    @broadcasts = []
  end

  def broadcast_to(target)
    @broadcasts << target
  end

  def respond_to?(method, include_private = false)
    method == :broadcast_to || super
  end

  def level
    @primary.level
  end
end

# Now load the Railtie (it checks for defined?(::Rails::Railtie))
require_relative "../../lib/opentrace/rails"

RSpec.describe "Rails integration" do
  before do
    configure_opentrace!
    stub_request(:post, "https://opentrace.test/api/logs")
      .to_return(status: 201, body: '{"count":1}')
    ActiveSupport::Notifications.reset!
  end

  # Helper to simulate Rails after_initialize by running the registered blocks
  def run_after_initialize(app)
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
  end

  describe "pre-7.1 logger wrapping (fallback)" do
    before do
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
            body = JSON.parse(req.body)
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
          .with { |req| JSON.parse(req.body)["level"] == "ERROR" }
      ).to have_been_made
    end

    it "logs 4xx responses as INFO" do
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
          .with { |req| JSON.parse(req.body)["level"] == "INFO" }
      ).to have_been_made
    end

    it "captures user_id when controller responds to current_user" do
      user_stub = Struct.new(:id).new(42)
      controller_stub = Object.new
      controller_stub.define_singleton_method(:current_user) { user_stub }

      payload = {
        controller: "ApiController",
        action: "index",
        method: "GET",
        path: "/api/items",
        status: 200,
        headers: nil,
        controller_instance: controller_stub
      }

      ActiveSupport::Notifications.instrument("process_action.action_controller", payload) {}
      sleep 0.5

      expect(
        a_request(:post, "https://opentrace.test/api/logs")
          .with { |req|
            body = JSON.parse(req.body)
            body["metadata"]["user_id"] == 42
          }
      ).to have_been_made
    end

    it "handles missing controller_instance gracefully" do
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

    it "handles current_user raising an error gracefully" do
      controller_stub = Object.new
      controller_stub.define_singleton_method(:current_user) { raise "auth error" }

      payload = {
        controller: "ApiController",
        action: "index",
        method: "GET",
        path: "/api/items",
        status: 200,
        headers: nil,
        controller_instance: controller_stub
      }

      expect {
        ActiveSupport::Notifications.instrument("process_action.action_controller", payload) {}
        sleep 0.3
      }.not_to raise_error
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
