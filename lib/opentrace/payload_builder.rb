# frozen_string_literal: true

module OpenTrace
  # Materializes deferred log entries (frozen Arrays) into payload Hashes.
  # All heavy work (context merge, timestamp formatting, Hash building)
  # runs on the background dispatch thread, keeping the request thread fast.
  #
  # Produces the v2 flat schema: top-level indexed fields, everything else in `body`.
  module PayloadBuilder
    module_function

    # The only entries the client enqueues are [:raw_document, doc] (deep-capture
    # request/job docs) and plain Hash payloads (standalone log/error/event docs).
    def materialize(entry, config)
      if entry.is_a?(Array) && entry[0] == :raw_document
        materialize_raw_document(entry[1], config)
      elsif entry.is_a?(Hash)
        entry # legacy direct payload
      end
    rescue StandardError => e
      OpenTrace.stats.increment(:payload_build_errors) if OpenTrace.respond_to?(:stats)
      $stderr.puts "[OpenTrace] PayloadBuilder error: #{e.class}: #{e.message}" if OpenTrace.respond_to?(:config) && OpenTrace.config.respond_to?(:debug) && OpenTrace.config.debug
      nil
    end

    def materialize_raw_document(doc, config)
      return nil unless doc.is_a?(Hash)

      req = doc[:request] || {}
      resp = doc[:response] || {}
      duration_ms = if doc[:duration_ms]
                      doc[:duration_ms].to_f.round(0)
                    elsif doc[:started_at]
                      ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - doc[:started_at]) * 1000).round(0)
                    else
                      0
                    end

      status = resp[:status] || resp[:response_status]
      # Requests that raised have no status (or 0) but must ship as errors.
      level = if doc[:error] then "error"
              elsif status.to_i >= 500 then "error"
              elsif status.to_i >= 400 then "warn"
              else "info"
              end

      message = "#{req[:method]} #{req[:path]} #{status} #{duration_ms}ms"

      payload = {
        ts: Time.now.utc.strftime("%Y-%m-%dT%H:%M:%S.%6NZ"),
        level: level,
        service: config.service,
        env: config.environment,
        message: message,
        event_type: "http.request",
        method: req[:method],
        path: req[:path],
        status: status.to_i,
        duration_ms: duration_ms.to_i,
        controller: doc[:controller],
      }

      payload[:trace_id] = doc[:trace_id] if doc[:trace_id]
      payload[:span_id] = doc[:span_id] if doc[:span_id]
      payload[:parent_span_id] = doc[:parent_span_id] if doc[:parent_span_id]
      payload[:request_id] = doc[:request_id] if doc[:request_id]

      # Promote identity fields from the per-request context to top-level indexed
      # fields; the remainder stays in body.context.
      context = doc[:context]
      if context.is_a?(Hash)
        context = context.dup
        user_id   = context.delete(:user_id)   || context.delete("user_id")
        tenant_id = context.delete(:tenant_id) || context.delete("tenant_id")
        session_id = context.delete(:session_id) || context.delete("session_id")
        payload[:user_id]    = user_id.to_s    if user_id
        payload[:tenant_id]  = tenant_id.to_s  if tenant_id
        payload[:session_id] = session_id.to_s if session_id
      end

      body = {}
      body[:request_headers] = req[:headers] if req[:headers]
      body[:request_params] = req[:params] if req[:params]
      body[:request_body] = req[:body] if req[:body]
      body[:response_headers] = resp[:headers] if resp[:headers]
      body[:response_body] = resp[:body] if resp[:body]
      body[:sql] = doc[:sql] if doc[:sql] && !doc[:sql].empty?
      body[:http] = doc[:http] if doc[:http] && !doc[:http].empty?
      body[:email] = doc[:email] if doc[:email] && !doc[:email].empty?
      body[:audit] = doc[:audit] if doc[:audit] && !doc[:audit].empty?
      body[:logs] = doc[:logs] if doc[:logs] && !doc[:logs].empty?
      body[:timeline] = doc[:timeline] if doc[:timeline] && !doc[:timeline].empty?
      body[:performance] = doc[:performance] if doc[:performance]
      body[:context] = context if context.is_a?(Hash) && !context.empty?

      if doc[:pending_explains] && defined?(ActiveRecord::Base)
        explain_results = run_pending_explains(doc[:pending_explains])
        body[:queries] = explain_results unless explain_results.empty?
      end

      payload[:body] = body unless body.empty?
      payload
    rescue StandardError
      nil
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
