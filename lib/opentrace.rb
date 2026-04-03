# frozen_string_literal: true

require "socket"
require "digest"
require_relative "opentrace/version"
require_relative "opentrace/config"
require_relative "opentrace/stats"
require_relative "opentrace/circuit_breaker"
require_relative "opentrace/ring_buffer"
require_relative "opentrace/serializer"
require_relative "opentrace/payload_builder"
require_relative "opentrace/pipeline"
require_relative "opentrace/client"
require_relative "opentrace/logger"
require_relative "opentrace/log_forwarder"
require_relative "opentrace/middleware"
require_relative "opentrace/trace_context"
require_relative "opentrace/sampler"
require_relative "opentrace/ulid"
require_relative "opentrace/request_buffer"
require_relative "opentrace/buffer_pool"
require_relative "opentrace/capture_rules"
require_relative "opentrace/memory_guard"
require_relative "opentrace/instrumentation_context"
require_relative "opentrace/sql_normalizer"
require_relative "opentrace/breadcrumbs"
require_relative "opentrace/source_context"
require_relative "opentrace/pii_scrubber"
require_relative "opentrace/local_vars"

module OpenTrace
  LEVEL_VALUES = { "DEBUG" => 0, "INFO" => 1, "WARN" => 2, "ERROR" => 3, "FATAL" => 4 }.freeze

  # Null object for when OpenTrace is not configured.
  # All methods are no-ops, avoiding nil checks on the hot path.
  class NilClient
    def initialize
      @nil_stats = NilStats.new
    end

    def enqueue(_) = nil
    def shutdown(timeout: 5) = nil
    def queue_size = 0
    def circuit_state = :closed
    def auth_suspended? = false
    def stats_snapshot = { queue_size: 0, circuit_state: :closed, auth_suspended: false }
    def stats = @nil_stats
    def supports?(_) = false
  end

  class NilStats
    def increment(_, _ = 1) = nil
    def get(_) = 0
    def to_h = { uptime_seconds: 0 }
    def reset! = nil
  end

  NULL_CLIENT = NilClient.new.freeze

  class << self
    def configure
      yield config
      config.finalize!
      reset_client!
    end

    def config
      @config ||= Config.new
    end

    def sampler
      @sampler ||= Sampler.new(config)
    end

    def log(level, message, metadata = {})
      return unless enabled?
      return unless config.level_allowed?(level)
      return if Fiber[:opentrace_logging]
      Fiber[:opentrace_logging] = true

      begin
        buffer = Fiber[:opentrace_buffer]
        if buffer
          # Inside a request -- append to buffer
          buffer.record_log(level: level.to_s.upcase, message: message.to_s, metadata: metadata)
          buffer.record_timeline(type: :log, name: message.to_s[0, 80])
        else
          # Standalone log -- build lightweight document and enqueue
          doc = build_standalone_doc(level, message.to_s, metadata)
          client.enqueue(doc)
        end
      ensure
        Fiber[:opentrace_logging] = nil
      end
    rescue StandardError
      # Never raise to the host app
    end

    def error(exception, metadata = {})
      return unless enabled?
      return if Fiber[:opentrace_logging]
      Fiber[:opentrace_logging] = true

      begin
        meta = metadata.is_a?(Hash) ? metadata.dup : {}
        meta[:exception_class]   = exception.class.name
        meta[:exception_message] = exception.message&.slice(0, 500)

        if exception.backtrace
          cleaned = clean_backtrace_for(exception)
          meta[:backtrace] = cleaned.first(15)
        end

        # Capture exception cause chain (max 5 deep)
        if exception.cause
          meta[:exception_causes] = build_cause_chain(exception.cause, depth: 0)
        end

        # Capture source code context for the error origin
        if exception.backtrace && config.source_context
          cleaned = meta[:backtrace] || clean_backtrace_for(exception)
          app_frame = cleaned&.first
          if app_frame
            source = SourceContext.extract(app_frame)
            meta[:source_context] = source if source
          end
        end

        # Attach current breadcrumbs to error
        crumbs = Fiber[:opentrace_breadcrumbs]
        if crumbs && !crumbs.empty?
          meta[:breadcrumbs] = crumbs.to_a
        end

        # Attach captured local variables (if capture_binding was called)
        if config.local_vars_capture && exception.instance_variable_defined?(:@__opentrace_local_vars__)
          meta[:local_variables] = exception.instance_variable_get(:@__opentrace_local_vars__)
        end

        # Fire on_error callback
        config.on_error&.call(exception, meta) rescue nil

        buffer = Fiber[:opentrace_buffer]
        if buffer
          # Inside a request -- record to buffer
          buffer.record_log(level: "ERROR", message: exception.message.to_s, metadata: meta)
          buffer.record_timeline(type: :error, name: "#{exception.class.name}: #{exception.message.to_s[0, 60]}")
        else
          doc = build_standalone_doc("ERROR", exception.message.to_s, meta, event_type: "error")
          client.enqueue(doc)
        end
      ensure
        Fiber[:opentrace_logging] = nil
      end
    rescue StandardError
      # Never raise to the host app
    end

    def event(event_type, message, metadata = {})
      return unless enabled?
      return if Fiber[:opentrace_logging]
      Fiber[:opentrace_logging] = true

      begin
        buffer = Fiber[:opentrace_buffer]
        if buffer
          # Inside a request -- record to buffer
          buffer.record_log(level: "INFO", message: message.to_s, metadata: metadata.merge(_event_type: event_type))
          buffer.record_timeline(type: :event, name: "#{event_type}: #{message.to_s[0, 60]}")
        else
          doc = build_standalone_doc("INFO", message.to_s, metadata, event_type: event_type.to_s)
          client.enqueue(doc)
        end
      ensure
        Fiber[:opentrace_logging] = nil
      end
    rescue StandardError
      # Never raise to the host app
    end

    def enabled?
      config.enabled?
    end

    def disable!
      config.enabled = false
    end

    def enable!
      config.enabled = true
    end

    def current_request_id
      Fiber[:opentrace_request_id]
    end

    def current_request_id=(id)
      Fiber[:opentrace_request_id] = id
    end

    # Override the auto-detected transaction name for the current request.
    def set_transaction_name(name)
      Fiber[:opentrace_transaction_name] = name.to_s
    rescue StandardError
      # Never raise
    end

    def current_transaction_name
      Fiber[:opentrace_transaction_name]
    end

    # Trace a block of code, recording its duration as a span.
    def trace(operation_name, resource: nil, tags: {})
      return yield(NilSpan::INSTANCE) unless enabled?

      begin
        span = Span.new(
          operation: operation_name,
          resource: resource,
          parent_span_id: Fiber[:opentrace_span_id],
          trace_id: Fiber[:opentrace_trace_id]
        )
        previous_span_id = Fiber[:opentrace_span_id]
        Fiber[:opentrace_span_id] = span.span_id
      rescue StandardError
        return yield(NilSpan::INSTANCE)
      end

      begin
        result = yield(span)
        span.finish(tags: tags)
        result
      rescue => e
        span.finish(error: e, tags: tags)
        raise
      ensure
        Fiber[:opentrace_span_id] = previous_span_id
      end
    end

    # Add a breadcrumb to the current request's trail.
    def add_breadcrumb(category, message, data = nil, level: "info")
      return unless enabled?
      buffer = Fiber[:opentrace_breadcrumbs] ||= BreadcrumbBuffer.new

      crumb = Breadcrumb.new(category: category, message: message, data: data, level: level)
      if config.before_breadcrumb
        crumb = config.before_breadcrumb.call(crumb) rescue crumb
        return unless crumb
      end

      buffer.add(crumb)
    rescue StandardError
      # Never raise
    end

    def current_breadcrumbs
      Fiber[:opentrace_breadcrumbs]&.to_a || []
    end

    def capture_binding(exception, binding_obj)
      return unless enabled? && config.local_vars_capture

      vars = LocalVars.capture(binding_obj)
      if vars && !vars.empty?
        exception.instance_variable_set(:@__opentrace_local_vars__, vars)
      end
    rescue StandardError
      # Never raise
    end

    def stats
      return {} unless @client
      @client.stats_snapshot
    end

    def reset_stats!
      @client&.stats&.reset!
    end

    def healthy?
      return false unless @client
      snapshot = @client.stats_snapshot
      snapshot[:circuit_state] == :closed && !snapshot[:auth_suspended]
    end

    def shutdown(timeout: 5)
      @client&.shutdown(timeout: timeout)
    end

    def reset!
      shutdown(timeout: 1)
      @config = nil
      @client = nil
      @static_context = nil
      @sampler = nil
      @at_exit_registered = nil
      InstrumentationContext.reset!
    end

    private

    def client
      @client ||= begin
        c = Client.new(config, sampler: sampler)
        register_at_exit_hook!
        c
      end
    end

    def register_at_exit_hook!
      return if @at_exit_registered
      @at_exit_registered = true
      at_exit { OpenTrace.shutdown(timeout: 2) }
    end

    def reset_client!
      @client&.shutdown(timeout: 1)
      @client = nil
      @static_context = nil
      @sampler = nil
    end

    def level_meets_threshold?(level)
      config.level_allowed?(level)
    end

    def static_context
      @static_context ||= {
        hostname: config.hostname || Socket.gethostname,
        pid: config.pid || Process.pid,
        git_sha: config.git_sha || ENV["REVISION"] || ENV["GIT_SHA"] || ENV["HEROKU_SLUG_COMMIT"]
      }.compact
    rescue StandardError
      {}
    end

    MAX_CAUSE_DEPTH = 5

    def build_cause_chain(exception, depth:)
      return nil if exception.nil? || depth >= MAX_CAUSE_DEPTH

      cause_entry = {
        class: exception.class.name,
        message: exception.message&.slice(0, 300)
      }

      if exception.backtrace
        cleaned = clean_backtrace_for(exception)
        cause_entry[:backtrace] = cleaned.first(5)
        cause_entry[:origin] = cleaned.first
      end

      chain = [cause_entry]
      if exception.cause
        nested = build_cause_chain(exception.cause, depth: depth + 1)
        chain.concat(nested) if nested
      end
      chain
    rescue StandardError
      nil
    end

    def clean_backtrace_for(exception)
      if defined?(::Rails) && ::Rails.respond_to?(:backtrace_cleaner)
        ::Rails.backtrace_cleaner.clean(exception.backtrace)
      else
        exception.backtrace.reject { |l| l.include?("/gems/") }
      end
    rescue StandardError
      exception.backtrace || []
    end

    # Build a standalone document for log/error/event calls outside a request.
    # Includes Fiber-local trace context when available.
    def build_standalone_doc(level, message, metadata, event_type: "log")
      ctx = resolve_context_raw
      context = {
        hostname: static_context[:hostname],
        pid: static_context[:pid]
      }.merge(ctx.is_a?(Hash) ? ctx : {})

      # Include Fiber-local trace context
      trace_id = Fiber[:opentrace_trace_id]
      span_id = Fiber[:opentrace_span_id]
      parent_span_id = Fiber[:opentrace_parent_span_id]
      request_id = Fiber[:opentrace_request_id]

      context[:trace_id] = trace_id if trace_id
      context[:span_id] = span_id if span_id
      context[:parent_span_id] = parent_span_id if parent_span_id
      context[:request_id] = request_id if request_id

      {
        id: ULID.generate,
        timestamp: Time.now.utc.strftime("%Y-%m-%dT%H:%M:%S.%6NZ"),
        level: level.to_s.upcase,
        service: config.service,
        environment: config.environment,
        version: static_context[:git_sha],
        context: context,
        event: {
          type: event_type,
          message: message,
          metadata: metadata
        }
      }
    rescue StandardError
      { level: level.to_s.upcase, event: { type: event_type, message: message, metadata: metadata } }
    end

    # Resolve user-configured context. Returns the raw value
    # (Hash or nil). Never raises.
    def resolve_context_raw
      case config.context
      when Proc then config.context.call
      when Hash then config.context
      end
    rescue StandardError
      {}
    end
  end

  # A timed span for custom instrumentation.
  class Span
    attr_reader :span_id, :operation, :resource

    def initialize(operation:, resource:, parent_span_id:, trace_id:)
      @operation = operation
      @resource = resource
      @span_id = TraceContext.generate_span_id
      @parent_span_id = parent_span_id
      @trace_id = trace_id
      @start = Process.clock_gettime(Process::CLOCK_REALTIME)
      @tags = {}
      @finished = false
    end

    def set_tag(key, value)
      @tags[key] = value
    end

    def finish(error: nil, tags: {})
      return if @finished
      @finished = true
      duration = Process.clock_gettime(Process::CLOCK_REALTIME) - @start

      meta = @tags.merge(tags)
      meta[:span_operation] = @operation
      meta[:span_resource] = @resource if @resource
      meta[:span_duration_ms] = (duration * 1000).round(2)

      if error
        meta[:exception_class] = error.class.name
        meta[:exception_message] = error.message&.slice(0, 500)
      end

      level = error ? "ERROR" : "INFO"
      OpenTrace.log(level, "span:#{@operation}", meta)

      # Record in RequestBuffer timeline if present
      buffer = Fiber[:opentrace_buffer]
      buffer&.record_timeline(type: :span, name: @operation, duration_ms: meta[:span_duration_ms])
    rescue StandardError
      # Never raise
    end
  end

  # Null object span for when OpenTrace is disabled
  class NilSpan
    INSTANCE = new.freeze
    def set_tag(_, _) = nil
    def finish(**) = nil
  end
end

# Auto-load Rails integration if Rails is present
require_relative "opentrace/rails" if defined?(::Rails::Railtie)
