# frozen_string_literal: true

module OpenTrace
  # Materializes deferred log entries (frozen Arrays) into payload Hashes.
  # All heavy work (context merge, timestamp formatting, Hash building)
  # runs on the background dispatch thread, keeping the request thread fast.
  #
  # Produces the v2 flat schema: top-level indexed fields, everything else in `body`.
  module PayloadBuilder
    module_function

    def materialize(entry, config)
      if entry.is_a?(Array)
        entry[0] == :request ? materialize_request(entry, config) : materialize_log(entry, config)
      elsif entry.is_a?(Hash)
        entry # legacy direct payload
      end
    rescue StandardError => e
      OpenTrace.stats.increment(:payload_build_errors) if OpenTrace.respond_to?(:stats)
      $stderr.puts "[OpenTrace] PayloadBuilder error: #{e.class}: #{e.message}" if OpenTrace.respond_to?(:config) && OpenTrace.config.respond_to?(:debug) && OpenTrace.config.debug
      nil
    end

    def materialize_log(entry, config)
      ts, level, message, metadata, ctx, request_id, trace_id,
        span_id, parent_span_id, req_summary, event_type = entry

      meta = ctx.is_a?(Hash) ? ctx.dup : {}
      meta.merge!(metadata) if metadata.is_a?(Hash)

      static_ctx = OpenTrace.send(:static_context)
      static_ctx.each { |k, v| meta[k] ||= v }

      # Extract trace_id from metadata if user provided it there
      meta_trace_id = meta.delete(:trace_id)
      effective_trace_id = meta_trace_id || trace_id

      # Promote indexed fields (remove from metadata to avoid duplication)
      commit_hash = meta.delete(:git_sha)
      effective_request_id = meta.delete(:request_id) || request_id
      error_class = meta.delete(:error_class)
      exception_message = meta.delete(:exception_message)
      meta.delete(:error_fingerprint) # server computes fingerprint
      backtrace = meta.delete(:backtrace)
      source_file, source_line = extract_source_location(backtrace)

      # Promote identity fields from metadata to top level
      user_id = meta.delete(:user_id)
      tenant_id = meta.delete(:tenant_id)
      session_id = meta.delete(:session_id)

      payload = {
        ts: format_timestamp(ts),
        level: level.to_s.downcase,
        service: config.service,
        env: config.environment,
        message: message.to_s
      }

      payload[:version] = commit_hash if commit_hash
      payload[:event_type] = event_type.to_s if event_type
      payload[:trace_id] = effective_trace_id.to_s if effective_trace_id
      payload[:span_id] = span_id if span_id
      payload[:parent_span_id] = parent_span_id if parent_span_id
      payload[:request_id] = effective_request_id.to_s if effective_request_id
      payload[:user_id] = user_id.to_s if user_id
      payload[:tenant_id] = tenant_id.to_s if tenant_id
      payload[:session_id] = session_id.to_s if session_id

      # Flatten request_summary fields to top level if present
      if req_summary.is_a?(Hash)
        payload[:method] = req_summary[:method] if req_summary[:method]
        payload[:path] = req_summary[:path] if req_summary[:path]
        payload[:status] = req_summary[:status] if req_summary[:status]
        payload[:duration_ms] = req_summary[:duration_ms].to_i if req_summary[:duration_ms]
        payload[:controller] = req_summary[:controller] if req_summary[:controller]
      end

      # Build body from remaining metadata + exception info
      body = {}
      body[:context] = meta.compact unless meta.empty?

      if error_class
        exc = { class: error_class }
        exc[:message] = exception_message&.slice(0, 500) if exception_message
        exc[:file] = source_file if source_file
        exc[:line] = source_line if source_line && source_line > 0
        exc[:backtrace] = backtrace.first(15) if backtrace.is_a?(Array) && !backtrace.empty?
        body[:exception] = exc
      end

      payload[:body] = body unless body.empty?
      payload
    end

    def materialize_request(entry, config)
      _, started, finished, controller, action, method, path, status,
        exc_class, exc_message, exc_backtrace, request_id, trace_id,
        span_id, parent_span_id, cached_ctx, collector, extra = entry

      duration_ms = (finished && started) ? (finished - started) * 1000.0 : 0.0

      meta = cached_ctx.is_a?(Hash) ? cached_ctx.dup : {}
      meta.merge!(extra) if extra.is_a?(Hash)

      static_ctx = OpenTrace.send(:static_context)
      static_ctx.each { |k, v| meta[k] ||= v }
      meta[:request_id] ||= request_id if request_id

      if cached_ctx.is_a?(Hash) && cached_ctx.key?(:user_id)
        meta[:user_id] = cached_ctx[:user_id]
      end

      exception_info = nil
      if exc_class
        cleaned_bt = exc_backtrace ? clean_backtrace(exc_backtrace) : nil
        source_file, source_line = extract_source_location(cleaned_bt)
        exception_info = { class: exc_class }
        exception_info[:message] = exc_message&.slice(0, 500) if exc_message
        exception_info[:file] = source_file if source_file
        exception_info[:line] = source_line if source_line && source_line > 0
        exception_info[:backtrace] = cleaned_bt.first(15) if cleaned_bt.is_a?(Array) && !cleaned_bt.empty?
      end

      # Run deferred EXPLAIN on background thread
      explain_results = nil
      if extra.is_a?(Hash) && extra[:pending_explains] && defined?(ActiveRecord::Base)
        explain_results = run_pending_explains(extra.delete(:pending_explains))
        explain_results = nil if explain_results.empty?
      end

      # Build collector summary data
      summary = collector&.summary
      db_ms = nil
      db_count = nil
      n_plus_one = nil
      slow_queries = nil
      dup_queries = nil
      view_ms = nil
      performance_body = nil
      queries_body = nil
      external_body = nil
      timeline_body = nil

      if collector && summary
        db_ms = summary[:sql_total_ms]&.round(1)
        db_count = summary[:sql_query_count]
        n_plus_one = summary[:n_plus_one_warning] || false
        slow_queries = summary[:sql_slowest_ms] ? 1 : 0
        dup_queries = 0 # placeholder; collector may provide this later

        view_ms = summary[:view_total_ms]&.round(1)

        # Build performance body section
        perf = {}
        perf[:view_ms] = view_ms if view_ms
        perf[:view_count] = summary[:view_render_count] if summary[:view_render_count]
        perf[:view_slowest_ms] = summary[:view_slowest_ms] if summary[:view_slowest_ms]
        perf[:view_slowest_template] = summary[:view_slowest_template] if summary[:view_slowest_template]
        perf[:memory_before_mb] = summary[:memory_before_mb] if summary[:memory_before_mb]
        perf[:memory_after_mb] = summary[:memory_after_mb] if summary[:memory_after_mb]
        perf[:memory_delta_mb] = summary[:memory_delta_mb] if summary[:memory_delta_mb]
        perf[:cache_reads] = summary[:cache_reads] if summary[:cache_reads]
        perf[:cache_hits] = summary[:cache_hits] if summary[:cache_hits]
        perf[:cache_writes] = summary[:cache_writes] if summary[:cache_writes]
        perf[:cache_hit_ratio] = summary[:cache_hit_ratio] if summary[:cache_hit_ratio]
        perf[:sql_slowest_ms] = summary[:sql_slowest_ms] if summary[:sql_slowest_ms]
        perf[:sql_slowest_name] = summary[:sql_slowest_name] if summary[:sql_slowest_name]
        perf[:http_external_count] = summary[:http_external_count] if summary[:http_external_count]
        perf[:http_external_total_ms] = summary[:http_external_total_ms] if summary[:http_external_total_ms]
        perf[:http_slowest_ms] = summary[:http_slowest_ms] if summary[:http_slowest_ms]
        perf[:http_slowest_host] = summary[:http_slowest_host] if summary[:http_slowest_host]

        # Compute time breakdown
        if duration_ms > 0
          sql_pct = [((collector.sql_total_ms / duration_ms) * 100).round(1), 100.0].min
          view_pct = [((collector.view_total_ms / duration_ms) * 100).round(1), 100.0].min
          http_pct = collector.http_count > 0 ? [((collector.http_total_ms / duration_ms) * 100).round(1), 100.0].min : 0.0
          other_pct = [100 - sql_pct - view_pct - http_pct, 0].max.round(1)
          perf[:time_breakdown] = {
            sql_pct: sql_pct,
            view_pct: view_pct,
            http_pct: http_pct,
            other_pct: other_pct
          }
        end

        performance_body = perf unless perf.empty?
        timeline_body = summary[:timeline] if summary[:timeline]
      end

      level = if exc_class
                "error"
              elsif status.to_i >= 500
                "error"
              elsif status.to_i >= 400
                "warn"
              else
                "info"
              end

      # Use custom transaction name if set
      transaction_name = meta.delete(:transaction_name)
      message = if transaction_name
                  "#{transaction_name} #{status} #{duration_ms.round(1)}ms"
                else
                  "#{method} #{path} #{status} #{duration_ms.round(1)}ms"
                end

      # Promote indexed fields (remove from metadata to avoid duplication)
      commit_hash = meta.delete(:git_sha)
      effective_request_id = meta.delete(:request_id) || request_id
      user_id = meta.delete(:user_id)
      tenant_id = meta.delete(:tenant_id)
      session_id = meta.delete(:session_id)

      # Remove fields that are now top-level or in body
      meta.delete(:exception_message)
      meta.delete(:error_class)
      meta.delete(:backtrace)
      meta.delete(:error_fingerprint)

      payload = {
        ts: format_timestamp(started),
        level: level,
        service: config.service,
        env: config.environment,
        message: message,
        event_type: "http.request"
      }

      payload[:version] = commit_hash if commit_hash
      payload[:trace_id] = trace_id.to_s if trace_id
      payload[:span_id] = span_id if span_id
      payload[:parent_span_id] = parent_span_id if parent_span_id
      payload[:request_id] = effective_request_id.to_s if effective_request_id
      payload[:user_id] = user_id.to_s if user_id
      payload[:tenant_id] = tenant_id.to_s if tenant_id
      payload[:session_id] = session_id.to_s if session_id

      # Flat request fields
      payload[:method] = method if method
      payload[:path] = path if path
      payload[:status] = status if status
      payload[:duration_ms] = duration_ms.round(0).to_i
      payload[:controller] = controller if controller

      # Flat DB fields
      payload[:db_ms] = db_ms.to_i if db_ms
      payload[:db_count] = db_count if db_count
      payload[:n_plus_one] = n_plus_one unless n_plus_one.nil?
      payload[:slow_queries] = slow_queries if slow_queries
      payload[:dup_queries] = dup_queries if dup_queries

      # Build body hash
      body = {}

      # Context: remaining metadata + transaction_name
      ctx = meta.compact
      ctx[:transaction_name] = transaction_name if transaction_name
      body[:context] = ctx unless ctx.empty?

      body[:performance] = performance_body if performance_body
      body[:queries] = explain_results if explain_results
      body[:timeline] = timeline_body if timeline_body
      body[:exception] = exception_info if exception_info

      payload[:body] = body unless body.empty?
      payload
    end

    def format_timestamp(ts)
      case ts
      when Float
        Time.at(ts).utc.strftime("%Y-%m-%dT%H:%M:%S.%6NZ")
      when Time
        ts.utc.strftime("%Y-%m-%dT%H:%M:%S.%6NZ")
      else
        Time.now.utc.strftime("%Y-%m-%dT%H:%M:%S.%6NZ")
      end
    end

    # Extract source file and line number from the first app-relevant backtrace line.
    # Format: "app/controllers/users_controller.rb:42:in `show'"
    def extract_source_location(backtrace)
      return [nil, nil] unless backtrace.is_a?(Array) && !backtrace.empty?

      line = backtrace.first.to_s
      parts = line.split(":", 3)
      return [nil, nil] if parts.length < 2

      file = parts[0]
      line_num = parts[1].to_i
      [file, line_num]
    rescue StandardError
      [nil, nil]
    end

    def clean_backtrace(backtrace)
      if defined?(::Rails) && ::Rails.respond_to?(:backtrace_cleaner)
        ::Rails.backtrace_cleaner.clean(backtrace)
      else
        backtrace.reject { |line| line.include?("/gems/") }
      end
    end

    def run_pending_explains(pending)
      pending.filter_map do |entry|
        plan = run_explain(entry[:sql])
        next unless plan
        {
          sql: entry[:sql].to_s.slice(0, 500),
          duration_ms: entry[:duration_ms],
          name: entry[:name],
          explain_plan: plan
        }
      end
    rescue StandardError
      []
    end

    def run_explain(sql)
      # Only EXPLAIN simple SELECTs -- reject anything suspicious
      normalized = sql.to_s.strip
      return nil unless normalized.match?(/\ASELECT\b/i)
      return nil if normalized.include?(";") # No multi-statement

      ActiveRecord::Base.connection_pool.with_connection do |conn|
        result = conn.execute("EXPLAIN #{normalized}")
        rows = result.respond_to?(:rows) ? result.rows : result.map(&:values)
        rows.flatten.join("\n").slice(0, 2000)
      end
    rescue StandardError
      nil
    end
  end
end
