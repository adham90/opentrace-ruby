# frozen_string_literal: true

if defined?(::Rails::Railtie)
  module OpenTrace
    class Railtie < ::Rails::Railtie
      # Use config.after_initialize so that config/initializers/ files
      # (where the user calls OpenTrace.configure) have already run.
      config.after_initialize do |app|
        next unless OpenTrace.enabled?

        # Insert middleware for request_id propagation
        if app.respond_to?(:middleware) && app.middleware.respond_to?(:use)
          app.middleware.use OpenTrace::Middleware
        end

        if Rails.logger.respond_to?(:broadcast_to)
          # Rails 7.1+: register as a broadcast target (non-invasive)
          Rails.logger.broadcast_to(OpenTrace::LogForwarder.new)
        else
          # Pre-7.1 fallback: wrap the logger directly
          if app.config.logger
            app.config.logger = OpenTrace::Logger.new(app.config.logger)
            Rails.logger = app.config.logger
          elsif Rails.logger
            Rails.logger = OpenTrace::Logger.new(Rails.logger)
          end
        end

        # Subscribe to controller request notifications
        ActiveSupport::Notifications.subscribe("process_action.action_controller") do |*args|
          event = ActiveSupport::Notifications::Event.new(*args)
          forward_request_log(event)
        rescue StandardError
          # Swallow - never affect the host app
        end

        # Subscribe to SQL query notifications
        if OpenTrace.config.sql_logging
          ActiveSupport::Notifications.subscribe("sql.active_record") do |*args|
            event = ActiveSupport::Notifications::Event.new(*args)
            forward_sql_log(event)
          rescue StandardError
            # Swallow
          end
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

          # Exception auto-capture
          if payload[:exception]
            metadata[:exception_class]   = payload[:exception][0]
            metadata[:exception_message] = truncate(payload[:exception][1], 500)
          end

          if payload[:exception_object]&.backtrace
            cleaned = clean_backtrace(payload[:exception_object].backtrace)
            metadata[:backtrace] = cleaned.first(15)
          end

          # Filtered request params
          extract_params(payload, metadata)

          level = if payload[:exception]
                    "ERROR"
                  elsif payload[:status].to_i >= 500
                    "ERROR"
                  elsif payload[:status].to_i >= 400
                    "WARN"
                  else
                    "INFO"
                  end
          message = "#{payload[:method]} #{payload[:path]} #{payload[:status]} #{event.duration&.round(1)}ms"

          OpenTrace.log(level, message, metadata)
        rescue StandardError
          # Swallow
        end

        def forward_sql_log(event)
          return unless OpenTrace.enabled?

          payload = event.payload
          duration = event.duration&.round(2)
          threshold = OpenTrace.config.sql_duration_threshold_ms

          # Skip if below threshold
          return if threshold > 0 && duration && duration < threshold

          # Skip SCHEMA queries (migrations, structure dumps)
          return if payload[:name] == "SCHEMA"

          metadata = {
            sql_name: payload[:name],
            sql: truncate(payload[:sql], 1000),
            sql_duration_ms: duration,
            sql_cached: payload[:cached] || false
          }.compact

          # Extract table name from SQL for easier filtering
          if payload[:sql] =~ /\b(?:FROM|INTO|UPDATE|JOIN)\s+[`"]?(\w+)[`"]?/i
            metadata[:sql_table] = $1
          end

          level = (duration && duration > 1000) ? "WARN" : "DEBUG"
          message = "SQL #{payload[:name]} #{duration}ms"

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

        def extract_params(payload, metadata)
          controller = payload[:controller_instance]
          return unless controller

          if controller.respond_to?(:request, true) && controller.request.respond_to?(:filtered_parameters)
            params = controller.request.filtered_parameters
            params = params.except("controller", "action")
            metadata[:params] = truncate_hash(params, 2048) unless params.empty?
          end
        rescue StandardError
          # Swallow
        end

        def truncate(str, max)
          return str if str.nil? || str.length <= max
          str[0, max] + "..."
        end

        def clean_backtrace(backtrace)
          if defined?(::Rails) && ::Rails.respond_to?(:backtrace_cleaner)
            ::Rails.backtrace_cleaner.clean(backtrace)
          else
            backtrace.reject { |line| line.include?("/gems/") }
          end
        end

        def truncate_hash(hash, max_bytes)
          json = JSON.generate(hash)
          return hash if json.bytesize <= max_bytes
          { _truncated: true, _size: json.bytesize }
        rescue StandardError
          { _truncated: true }
        end
      end
    end
  end
end
