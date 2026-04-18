# frozen_string_literal: true

require_relative "ulid"

module OpenTrace
  class RequestBuffer
    # Capture levels control how much data is included in the final document.
    # :minimal  — request identity + timing only (no bodies, no captures)
    # :standard — includes captures but strips request/response bodies
    # :full     — everything
    CAPTURE_LEVELS = %i[minimal standard full].freeze
    CAPTURE_LEVEL_RANK = { none: -1, minimal: 0, standard: 1, full: 2 }.freeze

    # Domains that can have individual capture-level overrides
    DOMAINS = %i[request sql http email file audit log timeline].freeze

    BASE_BYTE_ESTIMATE = 1024 # 1KB base overhead

    attr_accessor :id, :started_at, :event_type

    # Request/response fields (set by middleware)
    attr_accessor :request_method, :request_path, :request_headers, :request_body, :request_size,
                  :request_params, :content_type, :ip_address, :user_agent, :referer,
                  :cookies, :session_data,
                  :response_status, :response_headers, :response_body, :response_size

    # Performance fields (set by middleware)
    attr_accessor :memory_before, :memory_after

    # Context fields (set by middleware)
    attr_accessor :context, :controller, :action,
                  :request_id, :trace_id, :span_id, :parent_span_id

    # Job fields (for job.perform)
    attr_accessor :job_class, :job_id, :job_queue, :job_arguments, :job_executions,
                  :job_queue_latency_ms, :job_enqueued_at,
                  :triggered_by_request_id, :triggered_by_job_id

    # Read-only access to internal capture arrays (useful for tests/inspection)
    attr_reader :sql_captures, :http_captures, :email_captures, :file_captures,
                :audit_captures, :logs, :timeline

    def initialize(max_buffer_bytes: 1_048_576, max_audit_events: 50)
      @max_buffer_bytes = max_buffer_bytes
      @max_audit_events = max_audit_events

      # Pre-allocate arrays (reused across checkouts via reset!)
      @sql_captures   = []
      @http_captures  = []
      @email_captures = []
      @file_captures  = []
      @audit_captures = []
      @logs           = []
      @timeline       = []

      @audit_truncated = false

      # Identity — set on checkout
      @id         = nil
      @started_at = nil
      @event_type = nil

      # All other fields start nil
      reset_fields!
    end

    # ── Accumulation methods (called by subscribers during request) ──

    def record_sql(raw_sql:, normalized_sql: nil, binds: nil, duration_ms:, name: nil,
                   cached: false, row_count: nil, in_transaction: false,
                   fingerprint: nil, table: nil, caller_location: nil)
      @sql_captures << {
        raw_sql: raw_sql,
        normalized_sql: normalized_sql,
        binds: binds,
        duration_ms: duration_ms,
        name: name,
        cached: cached,
        row_count: row_count,
        in_transaction: in_transaction,
        fingerprint: fingerprint,
        table: table,
        caller_location: caller_location
      }
    end

    def record_http(method:, url:, host: nil, vendor: nil, status: nil, duration_ms:,
                    request_headers: nil, request_body: nil, response_headers: nil,
                    response_body: nil, response_size: nil, retry_attempt: nil,
                    error_class: nil)
      @http_captures << {
        method: method,
        url: url,
        host: host,
        vendor: vendor,
        status: status,
        duration_ms: duration_ms,
        request_headers: request_headers,
        request_body: request_body,
        response_headers: response_headers,
        response_body: response_body,
        response_size: response_size,
        retry_attempt: retry_attempt,
        error_class: error_class
      }
    end

    def record_email(mailer_class:, mailer_action:, from: nil, to: nil, subject: nil,
                     body_html: nil, body_text: nil, template: nil, variables: nil,
                     attachments: nil, delivery_status: nil, smtp_response: nil,
                     duration_ms: nil)
      @email_captures << {
        mailer_class: mailer_class,
        mailer_action: mailer_action,
        from: from,
        to: to,
        subject: subject,
        body_html: body_html,
        body_text: body_text,
        template: template,
        variables: variables,
        attachments: attachments,
        delivery_status: delivery_status,
        smtp_response: smtp_response,
        duration_ms: duration_ms
      }
    end

    def record_file(action:, filename:, size_bytes: nil, content_type: nil,
                    service: nil, key: nil, duration_ms: nil)
      @file_captures << {
        action: action,
        filename: filename,
        size_bytes: size_bytes,
        content_type: content_type,
        service: service,
        key: key,
        duration_ms: duration_ms
      }
    end

    def record_audit(action:, record_type:, record_id: nil, actor_id: nil,
                     actor_type: nil, changed_fields: nil, full_before: nil,
                     full_after: nil)
      if @audit_captures.size >= @max_audit_events
        @audit_truncated = true
        return
      end

      @audit_captures << {
        action: action,
        record_type: record_type,
        record_id: record_id,
        actor_id: actor_id,
        actor_type: actor_type,
        changed_fields: changed_fields,
        full_before: full_before,
        full_after: full_after
      }
    end

    def record_log(level:, message:, metadata: nil)
      @logs << {
        level: level,
        message: message,
        metadata: metadata
      }
    end

    def record_timeline(type:, name:, duration_ms: nil, extra: {})
      offset = if @started_at
                 ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - @started_at) * 1000).round(1)
               else
                 0.0
               end

      entry = {
        type: type,
        name: name,
        offset_ms: offset
      }
      entry[:duration_ms] = duration_ms if duration_ms
      entry.merge!(extra) unless extra.empty?

      @timeline << entry
    end

    # ── Output ──

    def byte_size
      size = BASE_BYTE_ESTIMATE

      size += @request_body.bytesize  if @request_body.is_a?(String)
      size += @response_body.bytesize if @response_body.is_a?(String)

      @sql_captures.each do |c|
        size += c[:raw_sql].bytesize if c[:raw_sql].is_a?(String)
      end

      @http_captures.each do |c|
        size += c[:request_body].bytesize  if c[:request_body].is_a?(String)
        size += c[:response_body].bytesize if c[:response_body].is_a?(String)
      end

      @email_captures.each do |c|
        size += c[:body_html].bytesize if c[:body_html].is_a?(String)
        size += c[:body_text].bytesize if c[:body_text].is_a?(String)
      end

      @logs.each do |c|
        size += c[:message].bytesize if c[:message].is_a?(String)
      end

      size
    end

    def exceeded_buffer?
      byte_size > @max_buffer_bytes
    end

    def audit_truncated?
      @audit_truncated
    end

    def to_document(capture_level:, domain_overrides: {})
      base_rank = CAPTURE_LEVEL_RANK.fetch(capture_level, 1)

      doc = {}

      # Identity
      doc[:id]         = @id
      doc[:event_type] = @event_type
      doc[:started_at] = @started_at

      # Request identity (always included)
      doc[:request] = build_request_section(base_rank, domain_overrides)

      # Response (always included at minimum level for status)
      doc[:response] = build_response_section(base_rank, domain_overrides)

      # Context
      doc[:context] = @context if @context

      # Controller/action
      doc[:controller] = @controller if @controller
      doc[:action]     = @action     if @action

      # Tracing
      doc[:request_id]      = @request_id      if @request_id
      doc[:trace_id]        = @trace_id        if @trace_id
      doc[:span_id]         = @span_id         if @span_id
      doc[:parent_span_id]  = @parent_span_id  if @parent_span_id

      # Performance
      if @memory_before || @memory_after
        doc[:performance] = {
          memory_before: @memory_before,
          memory_after: @memory_after
        }.compact
      end

      # Job fields
      if @job_class
        doc[:job] = {
          class: @job_class,
          id: @job_id,
          queue: @job_queue,
          arguments: @job_arguments,
          executions: @job_executions,
          queue_latency_ms: @job_queue_latency_ms,
          enqueued_at: @job_enqueued_at,
          triggered_by_request_id: @triggered_by_request_id,
          triggered_by_job_id: @triggered_by_job_id
        }.compact
      end

      # Domain captures — only include if above :minimal
      unless base_rank == 0 && !has_domain_override?(domain_overrides)
        doc[:sql]    = filter_captures(@sql_captures, :sql, base_rank, domain_overrides)       unless @sql_captures.empty? && !domain_included?(:sql, base_rank, domain_overrides)
        doc[:http]   = filter_captures(@http_captures, :http, base_rank, domain_overrides)     unless @http_captures.empty? && !domain_included?(:http, base_rank, domain_overrides)
        doc[:email]  = filter_captures(@email_captures, :email, base_rank, domain_overrides)   unless @email_captures.empty? && !domain_included?(:email, base_rank, domain_overrides)
        doc[:file]   = filter_captures(@file_captures, :file, base_rank, domain_overrides)     unless @file_captures.empty? && !domain_included?(:file, base_rank, domain_overrides)
        doc[:audit]  = filter_captures(@audit_captures, :audit, base_rank, domain_overrides)   unless @audit_captures.empty? && !domain_included?(:audit, base_rank, domain_overrides)
        doc[:logs]   = filter_captures(@logs, :log, base_rank, domain_overrides)               unless @logs.empty? && !domain_included?(:log, base_rank, domain_overrides)
        doc[:timeline] = @timeline.dup unless @timeline.empty?
      end

      doc[:audit_truncated] = true if @audit_truncated
      doc[:buffer_exceeded] = true if exceeded_buffer?

      doc.compact
    end

    # ── Lifecycle ──

    def reset!
      @id         = nil
      @started_at = nil
      @event_type = nil

      # Clear arrays but keep allocated memory
      @sql_captures.clear
      @http_captures.clear
      @email_captures.clear
      @file_captures.clear
      @audit_captures.clear
      @logs.clear
      @timeline.clear

      @audit_truncated = false

      reset_fields!
    end

    private

    def reset_fields!
      # Request/response
      @request_method  = nil
      @request_path    = nil
      @request_headers = nil
      @request_body    = nil
      @request_size    = nil
      @request_params  = nil
      @content_type    = nil
      @ip_address      = nil
      @user_agent      = nil
      @referer         = nil
      @cookies         = nil
      @session_data    = nil

      @response_status  = nil
      @response_headers = nil
      @response_body    = nil
      @response_size    = nil

      # Performance
      @memory_before = nil
      @memory_after  = nil

      # Context
      @context         = nil
      @controller      = nil
      @action          = nil
      @request_id      = nil
      @trace_id        = nil
      @span_id         = nil
      @parent_span_id  = nil

      # Job fields
      @job_class          = nil
      @job_id             = nil
      @job_queue          = nil
      @job_arguments      = nil
      @job_executions     = nil
      @job_queue_latency_ms = nil
      @job_enqueued_at    = nil
      @triggered_by_request_id = nil
      @triggered_by_job_id     = nil
    end

    def resolve_domain_rank(domain, base_rank, domain_overrides)
      override_key = :"#{domain}_capture"
      if domain_overrides.key?(override_key)
        CAPTURE_LEVEL_RANK.fetch(domain_overrides[override_key], base_rank)
      else
        base_rank
      end
    end

    def domain_included?(domain, base_rank, domain_overrides)
      resolve_domain_rank(domain, base_rank, domain_overrides) > 0
    end

    def has_domain_override?(domain_overrides)
      domain_overrides.any? { |_, v| CAPTURE_LEVEL_RANK.fetch(v, 0) > 0 }
    end

    def filter_captures(captures, domain, base_rank, domain_overrides)
      rank = resolve_domain_rank(domain, base_rank, domain_overrides)
      return nil if rank <= 0 # :none / :minimal — strip entirely
      return captures.map(&:dup) if rank >= 2 # :full — everything

      # :standard — strip body fields
      captures.map do |capture|
        filtered = capture.dup
        strip_bodies!(filtered, domain)
        filtered
      end
    end

    def strip_bodies!(capture, domain)
      case domain
      when :sql
        capture.delete(:raw_sql)
        capture.delete(:binds)
      when :http
        capture.delete(:request_body)
        capture.delete(:response_body)
        capture.delete(:request_headers)
        capture.delete(:response_headers)
      when :email
        capture.delete(:body_html)
        capture.delete(:body_text)
        capture.delete(:variables)
      when :audit
        capture.delete(:full_before)
        capture.delete(:full_after)
      end
    end

    def build_request_section(base_rank, domain_overrides)
      rank = resolve_domain_rank(:request, base_rank, domain_overrides)
      section = {
        method: @request_method,
        path: @request_path,
        content_type: @content_type,
        ip_address: @ip_address,
        user_agent: @user_agent,
        referer: @referer,
        size: @request_size
      }.compact

      if rank >= 2 # :full
        section[:headers]     = @request_headers if @request_headers
        section[:body]        = @request_body    if @request_body
        section[:params]      = @request_params  if @request_params
        section[:cookies]     = @cookies         if @cookies
        section[:session_data] = @session_data   if @session_data
      elsif rank >= 1 # :standard — params but no body
        section[:params]      = @request_params  if @request_params
      end

      section.empty? ? nil : section
    end

    def build_response_section(base_rank, domain_overrides)
      rank = resolve_domain_rank(:request, base_rank, domain_overrides)
      section = {
        status: @response_status,
        size: @response_size
      }.compact

      if rank >= 2 # :full
        section[:headers] = @response_headers if @response_headers
        section[:body]    = @response_body    if @response_body
      end

      section.empty? ? nil : section
    end
  end
end
