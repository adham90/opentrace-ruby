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

        # Subscribe to SQL query notifications (also increments N+1 counter and feeds collector)
        if OpenTrace.config.sql_logging
          ActiveSupport::Notifications.subscribe("sql.active_record") do |*args|
            # Skip Event allocation when outside a request and below threshold
            sql_count = Fiber[:opentrace_sql_count]
            collector = Fiber[:opentrace_collector]
            needs_forward = OpenTrace.config.sql_duration_threshold_ms <= 0

            next unless sql_count || collector || needs_forward

            event = ActiveSupport::Notifications::Event.new(*args)

            # Increment per-request SQL counter (Fiber-local, zero-cost)
            if sql_count
              Fiber[:opentrace_sql_count] = sql_count + 1
              Fiber[:opentrace_sql_total_ms] = (Fiber[:opentrace_sql_total_ms] || 0.0) + (event.duration || 0.0)
            end

            # Feed RequestCollector for timeline & summary
            if collector
              payload = event.payload
              unless payload[:name] == "SCHEMA"
                table = nil
                if payload[:sql] =~ /\b(?:FROM|INTO|UPDATE|JOIN)\s+[`"]?(\w+)[`"]?/i
                  table = $1
                end
                collector.record_sql(name: payload[:name], duration_ms: event.duration || 0.0, table: table)
              end
            end

            forward_sql_log(event)
          rescue StandardError
            # Swallow
          end
        else
          # Even when sql_logging is off, still count queries for N+1 detection and feed collector
          ActiveSupport::Notifications.subscribe("sql.active_record") do |*args|
            sql_count = Fiber[:opentrace_sql_count]
            collector = Fiber[:opentrace_collector]
            next unless sql_count || collector

            event = ActiveSupport::Notifications::Event.new(*args)

            if sql_count
              Fiber[:opentrace_sql_count] = sql_count + 1
              Fiber[:opentrace_sql_total_ms] = (Fiber[:opentrace_sql_total_ms] || 0.0) + (event.duration || 0.0)
            end

            # Feed RequestCollector for timeline & summary
            if collector
              payload = event.payload
              unless payload[:name] == "SCHEMA"
                table = nil
                if payload[:sql] =~ /\b(?:FROM|INTO|UPDATE|JOIN)\s+[`"]?(\w+)[`"]?/i
                  table = $1
                end
                collector.record_sql(name: payload[:name], duration_ms: event.duration || 0.0, table: table)
              end
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

        # View render tracking (only records when RequestCollector exists)
        %w[render_template.action_view render_partial.action_view].each do |event_name|
          ActiveSupport::Notifications.subscribe(event_name) do |*args|
            collector = Fiber[:opentrace_collector]
            next unless collector

            event = ActiveSupport::Notifications::Event.new(*args)
            template = event.payload[:identifier]
            # Shorten: /Users/deploy/app/views/orders/show.html.erb → orders/show.html.erb
            template = template.split("views/").last if template&.include?("views/")

            collector.record_view(template: template, duration_ms: event.duration || 0.0)
          rescue StandardError
            # Swallow
          end
        end

        # Cache operation tracking (only records when RequestCollector exists)
        %w[cache_read.active_support cache_write.active_support cache_delete.active_support].each do |event_name|
          ActiveSupport::Notifications.subscribe(event_name) do |*args|
            collector = Fiber[:opentrace_collector]
            next unless collector

            event = ActiveSupport::Notifications::Event.new(*args)
            action = event_name.split(".").first.sub("cache_", "").to_sym # :read, :write, :delete

            collector.record_cache(
              action: action,
              hit: event.payload[:hit],
              duration_ms: event.duration || 0.0
            )
          rescue StandardError
            # Swallow
          end
        end

        # External HTTP tracking (opt-in, prepends Net::HTTP)
        if OpenTrace.config.http_tracking
          require_relative "http_tracker"
          Net::HTTP.prepend(OpenTrace::HttpTracker)
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
            request_id: payload[:headers]&.env&.dig("action_dispatch.request_id")
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

          # Build structured request_summary from collector (or fall back to Fiber-locals)
          request_summary = nil
          collector = Fiber[:opentrace_collector]
          if collector
            summary = collector.summary
            request_summary = {
              controller: payload[:controller],
              action: payload[:action],
              method: payload[:method],
              path: payload[:path],
              status: payload[:status],
              duration_ms: event.duration&.round(1),
              sql_count: summary[:sql_query_count],
              sql_total_ms: summary[:sql_total_ms],
              sql_slowest_ms: summary[:sql_slowest_ms],
              sql_slowest_name: summary[:sql_slowest_name],
              n_plus_one: summary[:n_plus_one_warning] || false,
              view_count: summary[:view_render_count],
              view_total_ms: summary[:view_total_ms],
              view_slowest_ms: summary[:view_slowest_ms],
              view_slowest_template: summary[:view_slowest_template],
              cache_reads: summary[:cache_reads],
              cache_hits: summary[:cache_hits],
              cache_writes: summary[:cache_writes],
              cache_hit_ratio: summary[:cache_hit_ratio],
              http_external_count: summary[:http_external_count],
              http_external_total_ms: summary[:http_external_total_ms],
              http_slowest_ms: summary[:http_slowest_ms],
              http_slowest_host: summary[:http_slowest_host],
              memory_before_mb: summary[:memory_before_mb],
              memory_after_mb: summary[:memory_after_mb],
              memory_delta_mb: summary[:memory_delta_mb],
              timeline: summary[:timeline]
            }.compact

            # Compute time breakdown
            total = event.duration || 0.0
            if total > 0
              sql_pct = [((collector.sql_total_ms / total) * 100).round(1), 100.0].min
              view_pct = [((collector.view_total_ms / total) * 100).round(1), 100.0].min
              http_pct = collector.http_count > 0 ? [((collector.http_total_ms / total) * 100).round(1), 100.0].min : 0.0
              other_pct = [100 - sql_pct - view_pct - http_pct, 0].max.round(1)
              request_summary[:time_breakdown] = {
                sql_pct: sql_pct,
                view_pct: view_pct,
                http_pct: http_pct,
                other_pct: other_pct
              }
            end
          elsif Fiber[:opentrace_sql_count]
            # Fallback: Fiber-local counters when no collector
            metadata[:controller] = payload[:controller]
            metadata[:action] = payload[:action]
            metadata[:method] = payload[:method]
            metadata[:path] = payload[:path]
            metadata[:status] = payload[:status]
            metadata[:duration_ms] = event.duration&.round(1)
            metadata[:sql_query_count] = Fiber[:opentrace_sql_count]
            metadata[:sql_total_ms] = Fiber[:opentrace_sql_total_ms]&.round(1)
            metadata[:n_plus_one_warning] = true if Fiber[:opentrace_sql_count] > 20
          else
            # No collector, no Fiber-locals — include request identity in metadata
            metadata[:controller] = payload[:controller]
            metadata[:action] = payload[:action]
            metadata[:method] = payload[:method]
            metadata[:path] = payload[:path]
            metadata[:status] = payload[:status]
            metadata[:duration_ms] = event.duration&.round(1)
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

          OpenTrace.log(level, message, metadata, request_summary: request_summary)
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
          # Prefer user_id from cached request context (avoids calling
          # current_user which may trigger DB queries or auth logic)
          cached = Fiber[:opentrace_cached_context]
          return cached[:user_id] if cached&.key?(:user_id)

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
