# frozen_string_literal: true

if defined?(::Rails::Railtie)
  module OpenTrace
    class Railtie < ::Rails::Railtie
      initializer "opentrace.configure_logger", after: :initialize_logger do |app|
        next unless OpenTrace.enabled?

        app.config.logger = OpenTrace::Logger.new(app.config.logger || Rails.logger)
      end

      initializer "opentrace.subscribe_to_requests" do
        next unless OpenTrace.enabled?

        ActiveSupport::Notifications.subscribe("process_action.action_controller") do |*args|
          event = ActiveSupport::Notifications::Event.new(*args)
          forward_request_log(event)
        rescue StandardError
          # Swallow - never affect the host app
        end
      end

      class << self
        private

        def forward_request_log(event)
          return unless OpenTrace.enabled?

          payload = event.payload
          metadata = {
            request_id: payload[:headers]&.env&.dig("action_dispatch.request_id"),
            controller: payload[:controller],
            action: payload[:action],
            method: payload[:method],
            path: payload[:path],
            status: payload[:status],
            duration_ms: event.duration&.round(1)
          }.compact

          # Attempt to capture current user ID if available
          user_id = extract_user_id(payload)
          metadata[:user_id] = user_id if user_id

          level = payload[:status].to_i >= 500 ? "ERROR" : "INFO"
          message = "#{payload[:method]} #{payload[:path]} #{payload[:status]} #{event.duration&.round(1)}ms"

          OpenTrace.log(level, message, metadata)
        rescue StandardError
          # Swallow
        end

        def extract_user_id(payload)
          controller = payload[:controller_instance]
          return unless controller

          if controller.respond_to?(:current_user, true)
            user = controller.send(:current_user)
            user.respond_to?(:id) ? user.id : nil
          end
        rescue StandardError
          nil
        end
      end
    end
  end
end
