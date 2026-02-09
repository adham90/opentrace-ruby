# frozen_string_literal: true

# Shared Rails stubs for integration specs.
# Only define if not already defined (avoids double-load from rails_spec.rb).

unless defined?(::Rails)
  require "stringio"
  require "securerandom"

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

      def self.initializer(_name, _opts = {}, &block)
        @initializer_blocks ||= []
        @initializer_blocks << block
      end

      def self.initializer_blocks
        @initializer_blocks || []
      end
    end

    class Application
      class Configuration
        attr_accessor :logger
      end

      class MiddlewareStack
        attr_reader :entries

        def initialize
          @entries = []
        end

        def use(klass, *args)
          @entries << [klass, args]
        end
      end

      def config
        @config ||= Configuration.new
      end

      def middleware
        @middleware ||= MiddlewareStack.new
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

      @subscribers = Hash.new { |h, k| h[k] = [] }

      def self.subscribe(event_name, &block)
        @subscribers[event_name] << block
      end

      def self.instrument(event_name, payload = {})
        start_time = Time.now
        result = yield if block_given?
        end_time = Time.now

        @subscribers[event_name].each do |subscriber|
          subscriber.call(
            event_name, start_time, end_time, SecureRandom.hex(4), payload
          )
        end

        result
      end

      def self.reset!
        @subscribers = Hash.new { |h, k| h[k] = [] }
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

  # Load the Railtie (it checks for defined?(::Rails::Railtie))
  require_relative "../../lib/opentrace/rails"
end
