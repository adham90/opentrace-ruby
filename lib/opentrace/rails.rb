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

        # Subscribe to SQL query notifications (also increments N+1 counter)
        if OpenTrace.config.sql_logging
          ActiveSupport::Notifications.subscribe("sql.active_record") do |*args|
            event = ActiveSupport::Notifications::Event.new(*args)

            # Increment per-request SQL counter (Fiber-local, zero-cost)
            if Fiber[:opentrace_sql_count]
              Fiber[:opentrace_sql_count] += 1
              Fiber[:opentrace_sql_total_ms] = (Fiber[:opentrace_sql_total_ms] || 0.0) + (event.duration || 0.0)
            end

            forward_sql_log(event)
          rescue StandardError
            # Swallow
          end
        else
          # Even when sql_logging is off, still count queries for N+1 detection
          ActiveSupport::Notifications.subscribe("sql.active_record") do |*args|
            if Fiber[:opentrace_sql_count]
              event = ActiveSupport::Notifications::Event.new(*args)
              Fiber[:opentrace_sql_count] += 1
              Fiber[:opentrace_sql_total_ms] = (Fiber[:opentrace_sql_total_ms] || 0.0) + (event.duration || 0.0)
            end
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

        # Subscribe to deprecation warnings
        ActiveSupport::Notifications.subscribe("deprecation.rails") do |*args|
          event = ActiveSupport::Notifications::Event.new(*args)
          forward_deprecation_log(event)
        rescue StandardError
          # Swallow
        end

        # Start background monitors (opt-in)
        if OpenTrace.config.pool_monitoring
          require_relative "pool_monitor"
          @pool_monitor = OpenTrace::PoolMonitor.new(
            interval: OpenTrace.config.pool_monitoring_interval
          )
          @pool_monitor.start
        end

        if OpenTrace.config.queue_monitoring
          require_relative "queue_monitor"
          @queue_monitor = OpenTrace::QueueMonitor.new(
            interval: OpenTrace.config.queue_monitoring_interval
          )
          @queue_monitor.start
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

          # Exception auto-capture with fingerprinting
          if payload[:exception]
            metadata[:exception_class]   = payload[:exception][0]
            metadata[:exception_message] = truncate(payload[:exception][1], 500)
          end

          if payload[:exception_object]&.backtrace
            cleaned = clean_backtrace(payload[:exception_object].backtrace)
            metadata[:backtrace] = cleaned.first(15)
            metadata[:error_fingerprint] = OpenTrace.send(:compute_error_fingerprint,
              payload[:exception][0], cleaned)
          end

          # Filtered request params
          extract_params(payload, metadata)

          # Request headers
          extract_request_headers(payload, metadata)

          # N+1 query counter from Fiber-locals
          if Fiber[:opentrace_sql_count]
            metadata[:sql_query_count] = Fiber[:opentrace_sql_count]
            metadata[:sql_total_ms] = Fiber[:opentrace_sql_total_ms]&.round(1)
            metadata[:n_plus_one_warning] = true if Fiber[:opentrace_sql_count] > 20
          end

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

          # Queue latency calculation
          if job.respond_to?(:enqueued_at) && job.enqueued_at
            enqueued_at = case job.enqueued_at
                          when Time then job.enqueued_at
                          when String then Time.parse(job.enqueued_at)
                          end
            if enqueued_at
              queue_latency_s = Time.now.utc - enqueued_at.utc
              metadata[:queue_latency_ms] = (queue_latency_s * 1000).round(1) if queue_latency_s > 0
              metadata[:enqueued_at] = enqueued_at.utc.strftime("%Y-%m-%dT%H:%M:%S.%6NZ")
            end
          end

          # Capture arguments (truncated)
          if job.respond_to?(:arguments)
            args_json = JSON.generate(job.arguments)
            metadata[:job_arguments] = if args_json.bytesize > 512
                                         args_json[0, 512] + "..."
                                       else
                                         job.arguments
                                       end
          end

          # Capture exceptions from job failures with fingerprinting
          if payload[:exception_object]
            metadata[:exception_class]   = payload[:exception_object].class.name
            metadata[:exception_message] = truncate(payload[:exception_object].message, 500)
            if payload[:exception_object].backtrace
              cleaned = clean_backtrace(payload[:exception_object].backtrace)
              metadata[:backtrace] = cleaned.first(15)
              metadata[:error_fingerprint] = OpenTrace.send(:compute_error_fingerprint,
                payload[:exception_object].class.name, cleaned)
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

        def forward_deprecation_log(event)
          return unless OpenTrace.enabled?

          payload = event.payload
          message = payload[:message].to_s
          callsite = payload[:callstack]&.first&.to_s

          metadata = {
            deprecation_message: truncate(message, 500),
            deprecation_callsite: callsite
          }.compact

          metadata[:request_id] = OpenTrace.current_request_id if OpenTrace.current_request_id

          OpenTrace.log("WARN", "DEPRECATION: #{truncate(message, 200)}", metadata)
        rescue StandardError
          # Swallow
        end

        def extract_request_headers(payload, metadata)
          return unless payload[:headers]&.respond_to?(:env)

          env = payload[:headers].env
          headers = {
            request_content_type: env["CONTENT_TYPE"],
            request_accept: env["HTTP_ACCEPT"],
            request_user_agent: truncate(env["HTTP_USER_AGENT"], 200),
            request_referer: env["HTTP_REFERER"]
          }.compact
          metadata.merge!(headers) unless headers.empty?
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
