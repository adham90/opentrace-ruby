# frozen_string_literal: true

module OpenTrace
  # Materializes deferred log entries (frozen Arrays) into payload Hashes.
  # All heavy work (context merge, timestamp formatting, Hash building)
  # runs on the background dispatch thread, keeping the request thread fast.
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
      meta[:request_id] ||= request_id if request_id

      # Extract trace_id from metadata if user provided it there
      meta_trace_id = meta.delete(:trace_id)
      effective_trace_id = meta_trace_id || trace_id

      payload = {
        timestamp: format_timestamp(ts),
        level: level.to_s.upcase,
        service: config.service,
        environment: config.environment,
        message: message.to_s,
        metadata: meta.compact
      }

      payload[:event_type] = event_type.to_s if event_type
      payload[:trace_id] = effective_trace_id.to_s if effective_trace_id
      payload[:span_id] = span_id if span_id
      payload[:parent_span_id] = parent_span_id if parent_span_id
      payload[:request_summary] = req_summary if req_summary
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

      if exc_class
        meta[:exception_class] = exc_class
        meta[:exception_message] = exc_message&.slice(0, 500)
        if exc_backtrace
          cleaned = clean_backtrace(exc_backtrace)
          meta[:backtrace] = cleaned.first(15)
          meta[:error_fingerprint] = OpenTrace.send(:compute_error_fingerprint, exc_class, cleaned)
        end
      end

      # Run deferred EXPLAIN on background thread
      if extra.is_a?(Hash) && extra[:pending_explains] && defined?(ActiveRecord::Base)
        explain_results = run_pending_explains(extra.delete(:pending_explains))
        meta[:explain_plans] = explain_results unless explain_results.empty?
      end

      # Build request_summary from collector
      request_summary = nil
      if collector
        summary = collector.summary
        request_summary = build_request_summary(collector, summary, controller, action, method, path, status, duration_ms)
      else
        # No collector — include request identity in metadata
        meta[:controller] = controller
        meta[:action] = action
        meta[:method] = method
        meta[:path] = path
        meta[:status] = status
        meta[:duration_ms] = duration_ms.round(1)
      end

      level = if exc_class
                "ERROR"
              elsif status.to_i >= 500
                "ERROR"
              elsif status.to_i >= 400
                "WARN"
              else
                "INFO"
              end

      # Use custom transaction name if set
      transaction_name = meta.delete(:transaction_name)
      message = if transaction_name
                  "#{transaction_name} #{status} #{duration_ms.round(1)}ms"
                else
                  "#{method} #{path} #{status} #{duration_ms.round(1)}ms"
                end
      meta[:transaction_name] = transaction_name if transaction_name

      payload = {
        timestamp: format_timestamp(started),
        level: level,
        service: config.service,
        environment: config.environment,
        message: message,
        metadata: meta.compact
      }
      payload[:trace_id] = trace_id.to_s if trace_id
      payload[:span_id] = span_id if span_id
      payload[:parent_span_id] = parent_span_id if parent_span_id
      payload[:request_summary] = request_summary if request_summary
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
      # Only EXPLAIN simple SELECTs — reject anything suspicious
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

    def build_request_summary(collector, summary, controller, action, method, path, status, duration_ms)
      rs = {
        controller: controller,
        action: action,
        method: method,
        path: path,
        status: status,
        duration_ms: duration_ms.round(1),
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
      if duration_ms > 0
        sql_pct = [((collector.sql_total_ms / duration_ms) * 100).round(1), 100.0].min
        view_pct = [((collector.view_total_ms / duration_ms) * 100).round(1), 100.0].min
        http_pct = collector.http_count > 0 ? [((collector.http_total_ms / duration_ms) * 100).round(1), 100.0].min : 0.0
        other_pct = [100 - sql_pct - view_pct - http_pct, 0].max.round(1)
        rs[:time_breakdown] = {
          sql_pct: sql_pct,
          view_pct: view_pct,
          http_pct: http_pct,
          other_pct: other_pct
        }
      end

      rs
    end
  end
end
