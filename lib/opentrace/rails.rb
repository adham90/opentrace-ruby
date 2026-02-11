# frozen_string_literal: true

if defined?(::Rails::Railtie)
  module OpenTrace
    class Railtie < ::Rails::Railtie
      # Use config.after_initialize so that config/initializers/ files
      # (where the user calls OpenTrace.configure) have already run.
      # Register middleware early — before the stack is frozen
      initializer "opentrace.middleware" do |app|
        app.middleware.use OpenTrace::Middleware
      end

      config.after_initialize do |app|
        next unless OpenTrace.enabled?

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

        # Subscribe to ActiveJob notifications
        ActiveSupport::Notifications.subscribe("perform.active_job") do |*args|
          event = ActiveSupport::Notifications::Event.new(*args)
          forward_job_log(event)
        rescue StandardError
          # Swallow
        end
      end

      class << self
        private

        def forward_request_log(event)
          return unless OpenTrace.enabled?

          payload = event.payload
          return if ignored_path?(payload[:path])
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

        def forward_job_log(event)
          return unless OpenTrace.enabled?

          payload = event.payload
          job = payload[:job]

          metadata = {
            job_class: job.class.name,
            job_id: job.respond_to?(:job_id) ? job.job_id : nil,
            queue_name: job.respond_to?(:queue_name) ? job.queue_name : nil,
            executions: job.respond_to?(:executions) ? job.executions : nil,
            duration_ms: event.duration&.round(1)
          }.compact

          # Capture arguments (truncated)
          if job.respond_to?(:arguments)
            args_json = JSON.generate(job.arguments)
            metadata[:job_arguments] = if args_json.bytesize > 512
                                         args_json[0, 512] + "..."
                                       else
                                         job.arguments
                                       end
          end

          # Capture exceptions from job failures
          if payload[:exception_object]
            metadata[:exception_class]   = payload[:exception_object].class.name
            metadata[:exception_message] = truncate(payload[:exception_object].message, 500)
            if payload[:exception_object].backtrace
              metadata[:backtrace] = clean_backtrace(payload[:exception_object].backtrace).first(15)
            end
          end

          level = payload[:exception_object] ? "ERROR" : "INFO"
          message = if payload[:exception_object]
                      "Job #{job.class.name} FAILED (attempt #{job.respond_to?(:executions) ? job.executions : '?'})"
                    else
                      "Job #{job.class.name} completed #{event.duration&.round(1)}ms"
                    end

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

        def ignored_path?(path)
          return false if path.nil?

          OpenTrace.config.ignore_paths.any? do |entry|
            entry.is_a?(Regexp) ? entry.match?(path) : path == entry
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
