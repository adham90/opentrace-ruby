# frozen_string_literal: true

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

        # Subscribe to controller request notifications — push deferred :request array
        ActiveSupport::Notifications.subscribe("process_action.action_controller") do |name, started, finished, id, payload|
          forward_request_log(name, started, finished, id, payload)
        rescue StandardError
          # Swallow - never affect the host app
        end

        # SQL subscriber — lightweight counter + optional forwarding with filtering.
        # Cache config values at subscribe time to avoid repeated config lookups
        # on every single SQL query (can be 50-200+ per request).
        sql_logging = OpenTrace.config.sql_logging
        explain_enabled = OpenTrace.config.explain_slow_queries
        explain_threshold = OpenTrace.config.explain_threshold_ms
        ActiveSupport::Notifications.subscribe("sql.active_record") do |name, started, finished, id, payload|
          sql_count = Fiber[:opentrace_sql_count]
          collector = Fiber[:opentrace_collector]

          if sql_count || collector || sql_logging
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

            # Increment per-request SQL counter
            if sql_count
              Fiber[:opentrace_sql_count] = sql_count + 1
              Fiber[:opentrace_sql_total_ms] = (Fiber[:opentrace_sql_total_ms] || 0.0) + duration_ms
            end

            # Feed RequestCollector for summary (with fingerprint for duplicate detection)
            if collector
              fp = raw_sql ? simple_sql_fingerprint(raw_sql) : nil
              collector.record_sql(name: sql_name, duration_ms: duration_ms, fingerprint: fp)
            end

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
              collector = Fiber[:opentrace_collector]
              next unless collector

              duration_ms = (finished && started) ? (finished - started) * 1000.0 : 0.0
              template = payload[:identifier]
              template = template.split("views/").last if template&.include?("views/")

              collector.record_view(template: template, duration_ms: duration_ms)
            rescue StandardError
              # Swallow
            end
          end
        end

        # Cache operation tracking (opt-in)
        if OpenTrace.config.cache_tracking
          %w[cache_read.active_support cache_write.active_support cache_delete.active_support].each do |event_name|
            ActiveSupport::Notifications.subscribe(event_name) do |_name, started, finished, _id, payload|
              collector = Fiber[:opentrace_collector]
              next unless collector

              duration_ms = (finished && started) ? (finished - started) * 1000.0 : 0.0
              action = event_name.split(".").first.sub("cache_", "").to_sym

              collector.record_cache(
                action: action,
                hit: payload[:hit],
                duration_ms: duration_ms
              )
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

        if OpenTrace.config.runtime_metrics
          require_relative "runtime_monitor"
          @runtime_monitor = OpenTrace::RuntimeMonitor.new(
            interval: OpenTrace.config.runtime_metrics_interval
          )
          @runtime_monitor.start
        end
      end

      class << self
        private

        def forward_request_log(_name, started, finished, _id, payload)
          return unless OpenTrace.enabled?
          return if ignored_path?(payload[:path])

          extra = nil

          # Detailed request info (opt-in)
          if OpenTrace.config.detailed_request_log
            extra = {}
            extract_params(payload, extra)
            extract_request_headers(payload, extra)
          end

          # Always include params on error responses (status >= 500)
          # so the AI agent can diagnose what input caused the failure.
          if !extra&.key?(:params) && payload[:status].to_i >= 500
            extra ||= {}
            extract_params(payload, extra)
          end

          # SQL counters for non-collector path (only present for sampled requests)
          sql_count = Fiber[:opentrace_sql_count]
          if sql_count && !Fiber[:opentrace_collector]
            extra ||= {}
            extra[:sql_query_count] = sql_count
            extra[:sql_total_ms] = Fiber[:opentrace_sql_total_ms]&.round(1)
            extra[:n_plus_one_warning] = true if sql_count > 20
          end

          # Capture exception cause chain (eagerly, since errors are rare)
          exc_obj = payload[:exception_object]
          if exc_obj&.cause
            extra ||= {}
            extra[:exception_causes] = OpenTrace.send(:build_cause_chain, exc_obj.cause, depth: 0)
          end

          # Capture custom transaction name
          txn_name = Fiber[:opentrace_transaction_name]
          if txn_name
            extra ||= {}
            extra[:transaction_name] = txn_name
          end

          # Capture session ID
          session_id = Fiber[:opentrace_session_id]
          if session_id
            extra ||= {}
            extra[:session_id] = session_id
          end

          # Capture pending EXPLAIN queries (deferred to background thread)
          pending_explains = Fiber[:opentrace_pending_explains]
          if pending_explains && !pending_explains.empty?
            extra ||= {}
            extra[:pending_explains] = pending_explains
          end

          # Resolve context if not yet cached.
          # With sql_logging/log_forwarding off (default), no OpenTrace.log()
          # runs during the request, so the context proc is never evaluated.
          cached_ctx = Fiber[:opentrace_cached_context]
          unless cached_ctx
            cached_ctx = OpenTrace.send(:resolve_context_raw)
            cached_ctx = cached_ctx.is_a?(Hash) ? cached_ctx : {}
          end

          OpenTrace.client_enqueue_raw([
            :request,
            started,
            finished,
            payload[:controller],
            payload[:action],
            payload[:method],
            payload[:path],
            payload[:status],
            payload[:exception]&.first,
            payload[:exception]&.last,
            payload[:exception_object]&.backtrace,
            Fiber[:opentrace_request_id] || payload[:headers]&.env&.dig("action_dispatch.request_id"),
            Fiber[:opentrace_trace_id],
            Fiber[:opentrace_span_id],
            Fiber[:opentrace_parent_span_id],
            cached_ctx,
            Fiber[:opentrace_collector],
            extra
          ].freeze)
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
              metadata[:error_fingerprint] = OpenTrace.send(:compute_error_fingerprint,
                payload[:exception_object].class.name, cleaned)
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

        def extract_user_id
          cached = Fiber[:opentrace_cached_context]
          cached[:user_id] if cached&.key?(:user_id)
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
