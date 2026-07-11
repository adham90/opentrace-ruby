# frozen_string_literal: true

require "set"

if defined?(::Rails::Railtie)
  module OpenTrace
    class Railtie < ::Rails::Railtie
      SKIP_SQL_NAMES = Set.new(%w[SCHEMA EXPLAIN]).freeze

      # Use config.after_initialize so that config/initializers/ files
      # (where the user calls OpenTrace.configure) have already run.
      # Register middleware early — before the stack is frozen
      initializer "opentrace.middleware" do |app|
        app.middleware.use OpenTrace::Middleware
      end

      config.after_initialize do |app|
        next unless OpenTrace.enabled?

        # Rails Error Reporter subscriber (Rails 7.0+) — captures ALL exceptions
        # including those rescued by rescue_from in controllers.
        if defined?(Rails.error) && Rails.error.respond_to?(:subscribe)
          require_relative "error_subscriber"
          Rails.error.subscribe(OpenTrace::ErrorSubscriber.new)
        end

        # Automatic log trace injection (opt-in) — wraps Rails logger formatter
        if OpenTrace.config.log_trace_injection
          require_relative "trace_formatter"
          original_formatter = Rails.logger.formatter
          Rails.logger.formatter = OpenTrace::TraceFormatter.new(original_formatter)
        end

        # Log forwarding (opt-in) — registers LogForwarder/Logger wrapper
        if OpenTrace.config.log_forwarding
          if Rails.logger.respond_to?(:broadcast_to)
            Rails.logger.broadcast_to(OpenTrace::LogForwarder.new)
          else
            if app.config.logger
              app.config.logger = OpenTrace::Logger.new(app.config.logger)
              Rails.logger = app.config.logger
            elsif Rails.logger
              Rails.logger = OpenTrace::Logger.new(Rails.logger)
            end
          end
        end

        # Subscribe to controller request notifications — populate buffer with Rails-level details
        ActiveSupport::Notifications.subscribe("process_action.action_controller") do |name, started, finished, id, payload|
          buffer = Fiber[:opentrace_buffer]
          next unless buffer

          buffer.controller = payload[:controller]
          buffer.action = payload[:action]
          buffer.response_status = payload[:status]

          # Capture exception info
          if payload[:exception_object]
            exc = payload[:exception_object]
            buffer.record_log(
              level: "ERROR",
              message: "#{exc.class}: #{exc.message}",
              metadata: {
                exception_class: exc.class.name,
                exception_message: exc.message&.slice(0, 500),
                backtrace: exc.backtrace&.first(15)
              }
            )
          end

          # Capture params (detailed_request_log or on error)
          if OpenTrace.config.detailed_request_log || payload[:status].to_i >= 500
            extract_params_to_buffer(payload, buffer)
          end
        rescue StandardError
          # Swallow - never affect the host app
        end

        # SQL subscriber — optional forwarding with filtering + buffer recording.
        # Cache config values at subscribe time to avoid repeated config lookups
        # on every single SQL query (can be 50-200+ per request).
        sql_logging = OpenTrace.config.sql_logging
        explain_enabled = OpenTrace.config.explain_slow_queries
        explain_threshold = OpenTrace.config.explain_threshold_ms
        ActiveSupport::Notifications.subscribe("sql.active_record") do |name, started, finished, id, payload|
          buffer = Fiber[:opentrace_buffer]

          if buffer || sql_logging
            # Filter useless queries that fire dozens of times per request
            sql_name = payload[:name]
            if SKIP_SQL_NAMES.include?(sql_name)
              next
            end

            raw_sql = payload[:sql]
            if raw_sql && (raw_sql.start_with?("PRAGMA") ||
                           raw_sql.start_with?("BEGIN") ||
                           raw_sql.start_with?("COMMIT") ||
                           raw_sql.start_with?("ROLLBACK") ||
                           raw_sql.start_with?("SAVEPOINT") ||
                           raw_sql.start_with?("RELEASE"))
              next
            end

            duration_ms = (finished && started) ? (finished - started) * 1000.0 : 0.0

            # Flag slow queries for background EXPLAIN (opt-in)
            if explain_enabled &&
               duration_ms > explain_threshold &&
               explainable_query?(raw_sql)
              pending = Fiber[:opentrace_pending_explains] ||= []
              if pending.size < 3
                pending << { sql: raw_sql, duration_ms: duration_ms, name: sql_name }
              end
            end

            # Forward individual SQL log (opt-in)
            if sql_logging
              forward_sql_log(payload, duration_ms)
            end

            # Record to RequestBuffer
            if buffer
              # Capture bind values from the notification payload
              binds = nil
              if payload[:type_casted_binds].is_a?(Array)
                binds = payload[:type_casted_binds].map { |v| v.is_a?(ActiveModel::Attribute) ? v.value : v } rescue payload[:type_casted_binds]
              elsif payload[:binds].is_a?(Array)
                binds = payload[:binds].map { |b| b.respond_to?(:value) ? b.value : b } rescue nil
              end

              # Detect if we're inside a transaction
              in_transaction = false
              if defined?(ActiveRecord::Base)
                in_transaction = ActiveRecord::Base.connection.open_transactions > 0 rescue false
              end

              # Caller location — find first app frame
              caller_loc = caller_locations(1, 20)&.find { |l| l.path&.include?("app/") || l.path&.include?("lib/") }
              caller_str = caller_loc ? "#{caller_loc.path}:#{caller_loc.lineno}" : nil

              fp = raw_sql ? simple_sql_fingerprint(raw_sql) : nil

              buffer.record_sql(
                raw_sql: raw_sql,
                normalized_sql: nil,
                binds: binds,
                duration_ms: duration_ms,
                name: sql_name,
                cached: payload[:cached] || false,
                row_count: payload[:row_count],
                in_transaction: in_transaction,
                fingerprint: fp,
                table: (raw_sql =~ /\b(?:FROM|INTO|UPDATE|JOIN)\s+[`"]?(\w+)[`"]?/i) ? $1 : nil,
                caller_location: caller_str
              )

              buffer.record_timeline(type: :sql, name: sql_name, duration_ms: duration_ms)

              # Detect bulk operations (UPDATE/DELETE/INSERT without matching AR callback)
              # These skip ActiveRecord callbacks, so the audit trail misses them.
              begin
                if OpenTrace.config.audit_tracking
                  bulk_sql = raw_sql.to_s.strip
                  if bulk_sql.match?(/\A(UPDATE|DELETE FROM|INSERT INTO)\b/i) &&
                     !bulk_sql.match?(/\AINSERT INTO "?(\w+)"?\s+VALUES\s+\(/i) # Skip single-row INSERTs (AR callbacks handle these)
                    # Check if this looks like a bulk operation (has WHERE clause for UPDATE/DELETE, or multi-row INSERT)
                    is_bulk = case
                              when bulk_sql.match?(/\AUPDATE\b/i)
                                true # All UPDATEs in SQL subscriber are from update_all (AR single-row updates use callbacks)
                              when bulk_sql.match?(/\ADELETE FROM\b/i)
                                true # All DELETEs in SQL subscriber are from delete_all
                              when bulk_sql.match?(/\AINSERT INTO\b.*VALUES.*,.*VALUES/i) || bulk_sql.match?(/\AINSERT INTO\b.*SELECT/i)
                                true # Multi-row INSERT or INSERT...SELECT
                              else
                                false
                              end

                    if is_bulk
                      # Extract table name
                      table = if bulk_sql =~ /\b(?:UPDATE|DELETE FROM|INSERT INTO)\s+[`"]?(\w+)[`"]?/i
                                $1
                              end

                      buffer.record_audit(
                        action: "bulk_#{bulk_sql.split(/\s+/).first.downcase}",
                        record_type: table,
                        record_id: nil,
                        actor_id: nil,
                        actor_type: "SQL",
                        changed_fields: nil,
                        full_before: nil,
                        full_after: { "sql" => raw_sql.to_s.slice(0, 500), "note" => "bulk operation — no before/after diff available" }
                      )
                    end
                  end
                end
              rescue StandardError
                # Never affect the host app
              end
            end
          end
        rescue StandardError
          # Swallow
        end

        # Subscribe to ActiveJob notifications — raw args, no Event.new allocation
        ActiveSupport::Notifications.subscribe("perform.active_job") do |name, started, finished, id, payload|
          duration_ms = (finished && started) ? (finished - started) * 1000.0 : 0.0
          forward_job_log(payload, duration_ms)
        rescue StandardError
          # Swallow
        end

        # Deprecation warnings (opt-in)
        if OpenTrace.config.deprecation_tracking
          ActiveSupport::Notifications.subscribe("deprecation.rails") do |_name, _started, _finished, _id, payload|
            forward_deprecation_log(payload)
          rescue StandardError
            # Swallow
          end
        end

        # View render tracking (opt-in)
        if OpenTrace.config.view_tracking
          %w[render_template.action_view render_partial.action_view].each do |event_name|
            ActiveSupport::Notifications.subscribe(event_name) do |_name, started, finished, _id, payload|
              buffer = Fiber[:opentrace_buffer]
              next unless buffer

              duration_ms = (finished && started) ? (finished - started) * 1000.0 : 0.0
              template = payload[:identifier]
              template = template.split("views/").last if template&.include?("views/")

              buffer.record_timeline(type: :view, name: template, duration_ms: duration_ms)
            rescue StandardError
              # Swallow
            end
          end
        end

        # Cache operation tracking (opt-in)
        if OpenTrace.config.cache_tracking
          %w[cache_read.active_support cache_write.active_support cache_delete.active_support].each do |event_name|
            ActiveSupport::Notifications.subscribe(event_name) do |_name, started, finished, _id, payload|
              buffer = Fiber[:opentrace_buffer]
              next unless buffer

              duration_ms = (finished && started) ? (finished - started) * 1000.0 : 0.0
              action = event_name.split(".").first.sub("cache_", "").to_sym

              buffer.record_timeline(type: :cache, name: "cache_#{action}", duration_ms: duration_ms)
            rescue StandardError
              # Swallow
            end
          end
        end

        # ActionMailer capture — records to RequestBuffer
        ActiveSupport::Notifications.subscribe("deliver.action_mailer") do |_name, started, finished, _id, payload|
          buffer = Fiber[:opentrace_buffer]
          next unless buffer

          duration_ms = (finished && started) ? (finished - started) * 1000.0 : 0.0
          mail = payload[:mail]

          buffer.record_email(
            mailer_class: payload[:mailer],
            mailer_action: payload[:action] || payload[:method_name],
            from: mail&.from&.first,
            to: mail&.to,
            subject: mail&.subject,
            body_html: mail&.html_part&.decoded,
            body_text: mail&.text_part&.decoded || mail&.body&.decoded,
            template: nil,
            variables: nil,
            attachments: mail&.attachments&.map { |a| { name: a.filename, size: a.body&.raw_source&.bytesize, content_type: a.content_type } },
            delivery_status: payload[:perform_deliveries] == false ? "skipped" : "delivered",
            smtp_response: nil,
            duration_ms: duration_ms
          )

          buffer.record_timeline(type: :email, name: "#{payload[:mailer]}##{payload[:action] || payload[:method_name]}", duration_ms: duration_ms)
        rescue StandardError
          # Swallow
        end

        # ActiveStorage file operation tracking — records to RequestBuffer
        if defined?(ActiveStorage)
          %w[service_upload.active_storage service_download.active_storage service_delete.active_storage].each do |event_name|
            ActiveSupport::Notifications.subscribe(event_name) do |_name, started, finished, _id, payload|
              buffer = Fiber[:opentrace_buffer]
              next unless buffer

              duration_ms = (finished && started) ? (finished - started) * 1000.0 : 0.0
              action = event_name.split(".").first.sub("service_", "")

              buffer.record_file(
                action: action,
                filename: payload[:key],
                size_bytes: payload[:bytesize] || payload[:content_length],
                content_type: payload[:content_type],
                service: payload[:service],
                key: payload[:key],
                duration_ms: duration_ms
              )

              buffer.record_timeline(type: :file, name: "#{action} #{payload[:key]}", duration_ms: duration_ms)
            rescue StandardError
              # Swallow
            end
          end
        end

        # External HTTP tracking (opt-in, prepends Net::HTTP)
        if OpenTrace.config.http_tracking
          require_relative "http_tracker"
          Net::HTTP.prepend(OpenTrace::HttpTracker)
        end

        # Start background monitors (opt-in). Monitor threads do not survive
        # fork(), so in forking servers (Puma) call
        # OpenTrace::Railtie.restart_monitors_after_fork! from on_worker_boot.
        if OpenTrace.config.pool_monitoring
          require_relative "pool_monitor"
          monitor = OpenTrace::PoolMonitor.new(interval: OpenTrace.config.pool_monitoring_interval)
          monitor.start
          OpenTrace::Railtie.register_monitor(monitor)
        end

        if OpenTrace.config.queue_monitoring
          require_relative "queue_monitor"
          monitor = OpenTrace::QueueMonitor.new(interval: OpenTrace.config.queue_monitoring_interval)
          monitor.start
          OpenTrace::Railtie.register_monitor(monitor)
        end

        if OpenTrace.config.runtime_metrics
          require_relative "runtime_monitor"
          monitor = OpenTrace::RuntimeMonitor.new(interval: OpenTrace.config.runtime_metrics_interval)
          monitor.start
          OpenTrace::Railtie.register_monitor(monitor)
        end

        # Audit trail (opt-in)
        if OpenTrace.config.audit_tracking && defined?(ActiveRecord::Base)
          require_relative "audit_tracker"
          ActiveRecord::Base.include(OpenTrace::AuditTracker)
        end
      end

      class << self
        # Registered background monitors (pool/queue/runtime), so they can be
        # restarted after a fork.
        def register_monitor(monitor)
          (@monitors ||= []) << monitor
        end

        # Restart every registered monitor whose thread was lost across a fork.
        # Call from the forking server's after-fork hook (e.g. Puma on_worker_boot).
        def restart_monitors_after_fork!
          (@monitors || []).each(&:restart_after_fork!)
        end

        private

        def extract_params_to_buffer(payload, buffer)
          # ActionController::Instrumentation never sets :controller_instance.
          # Prefer the request's filtered_parameters (secrets already masked),
          # falling back to the raw :params on the notification payload.
          request = payload[:request]
          params = if request.respond_to?(:filtered_parameters)
                     request.filtered_parameters
                   else
                     payload[:params]
                   end
          return unless params.is_a?(Hash)

          filtered = params.reject { |k, _| k.to_s == "controller" || k.to_s == "action" }
          buffer.request_params = filtered unless filtered.empty?
        rescue StandardError
          # Swallow
        end

        def forward_job_log(payload, duration_ms)
          return unless OpenTrace.enabled?

          job = payload[:job]

          metadata = {
            job_class: job.class.name,
            job_id: job.respond_to?(:job_id) ? job.job_id : nil,
            queue_name: job.respond_to?(:queue_name) ? job.queue_name : nil,
            executions: job.respond_to?(:executions) ? job.executions : nil,
            duration_ms: duration_ms&.round(1)
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
            end
          end

          level = payload[:exception_object] ? "ERROR" : "INFO"
          message = if payload[:exception_object]
                      "Job #{job.class.name} FAILED (attempt #{job.respond_to?(:executions) ? job.executions : '?'})"
                    else
                      "Job #{job.class.name} completed #{duration_ms&.round(1)}ms"
                    end

          OpenTrace.log(level, message, metadata)
        rescue StandardError
          # Swallow
        end

        def forward_sql_log(payload, duration_ms)
          return unless OpenTrace.enabled?

          duration = duration_ms&.round(2)

          # Determine level BEFORE doing any expensive work (regex, hashing).
          # Most SQL logs are DEBUG — skip everything if DEBUG is filtered.
          level = (duration && duration > 1000) ? "WARN" : "DEBUG"
          return unless OpenTrace.config.level_allowed?(level)

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

          # SQL normalization (replaces literals with ? placeholders)
          if OpenTrace.config.sql_normalization && payload[:sql]
            metadata[:sql_normalized] = SqlNormalizer.normalize(payload[:sql])
            metadata[:sql_fingerprint] = SqlNormalizer.fingerprint(payload[:sql])
          end

          # Extract table name from SQL for easier filtering
          if payload[:sql] =~ /\b(?:FROM|INTO|UPDATE|JOIN)\s+[`"]?(\w+)[`"]?/i
            metadata[:sql_table] = $1
          end

          message = "SQL #{payload[:name]} #{duration}ms"

          OpenTrace.log(level, message, metadata)
        rescue StandardError
          # Swallow
        end

        def forward_deprecation_log(payload)
          return unless OpenTrace.enabled?

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

        def simple_sql_fingerprint(sql)
          normalized = sql.gsub(/'[^']*'/, "?").gsub(/\b\d+\b/, "?")
          Digest::MD5.hexdigest(normalized)[0, 8]
        rescue StandardError
          nil
        end

        def explainable_query?(sql)
          sql && (sql.start_with?("SELECT") || sql.start_with?("select"))
        end

        def ignored_path?(path)
          return false if path.nil?

          OpenTrace.config.ignore_paths.any? do |entry|
            entry.is_a?(Regexp) ? entry.match?(path) : path == entry
          end
        end
      end
    end
  end
end
