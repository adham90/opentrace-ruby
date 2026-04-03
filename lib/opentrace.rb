# frozen_string_literal: true

require "socket"
require "digest"
require_relative "opentrace/version"
require_relative "opentrace/config"
require_relative "opentrace/stats"
require_relative "opentrace/circuit_breaker"
require_relative "opentrace/client"
require_relative "opentrace/logger"
require_relative "opentrace/log_forwarder"
require_relative "opentrace/middleware"
require_relative "opentrace/trace_context"
require_relative "opentrace/sampler"
require_relative "opentrace/payload_builder"
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

    # Push a deferred log entry as a frozen Array.
    # All heavy work (Hash building, timestamp formatting, context merge)
    # is deferred to the background dispatch thread via PayloadBuilder.
    def log(level, message, metadata = {}, request_summary: nil)
      return unless enabled?
      return unless config.level_allowed?(level)

      # Re-entrance guard: prevent recursive logging if the context proc
      # or any subscriber triggers another log call (e.g. via ActiveRecord)
      return if Fiber[:opentrace_logging]
      Fiber[:opentrace_logging] = true

      begin
        # Read cached context (set by middleware) or resolve fresh
        ctx = Fiber[:opentrace_cached_context]
        unless ctx
          ctx = resolve_context_raw
          # Cache if inside a request (middleware sets request_id)
          if Fiber[:opentrace_request_id]
            ctx = (ctx.is_a?(Hash) ? ctx : {}).freeze
            Fiber[:opentrace_cached_context] = ctx
          end
        end

        client.enqueue([
          Process.clock_gettime(Process::CLOCK_REALTIME), # float timestamp
          level,
          message,
          metadata,
          ctx,
          Fiber[:opentrace_request_id],
          Fiber[:opentrace_trace_id],
          Fiber[:opentrace_span_id],
          Fiber[:opentrace_parent_span_id],
          request_summary,
          nil # event_type
        ].freeze)
      ensure
        Fiber[:opentrace_logging] = nil
      end
    rescue StandardError
      # Never raise to the host app
    end

    def error(exception, metadata = {})
      return unless enabled?

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
      buffer = Fiber[:opentrace_breadcrumbs]
      if buffer && !buffer.empty?
        meta[:breadcrumbs] = buffer.to_a
      end

      # Attach captured local variables (if capture_binding was called)
      if config.local_vars_capture && exception.instance_variable_defined?(:@__opentrace_local_vars__)
        meta[:local_variables] = exception.instance_variable_get(:@__opentrace_local_vars__)
      end

      # Fire on_error callback
      config.on_error&.call(exception, meta) rescue nil

      log("ERROR", exception.message.to_s, meta)
    rescue StandardError
      # Never raise to the host app
    end

    def event(event_type, message, metadata = {})
      return unless enabled?
      return if Fiber[:opentrace_logging]
      Fiber[:opentrace_logging] = true

      begin
        ctx = Fiber[:opentrace_cached_context]
        unless ctx
          ctx = resolve_context_raw
          if Fiber[:opentrace_request_id]
            ctx = (ctx.is_a?(Hash) ? ctx : {}).freeze
            Fiber[:opentrace_cached_context] = ctx
          end
        end

        client.enqueue([
          Process.clock_gettime(Process::CLOCK_REALTIME),
          "INFO",
          message,
          metadata,
          ctx,
          Fiber[:opentrace_request_id],
          Fiber[:opentrace_trace_id],
          Fiber[:opentrace_span_id],
          Fiber[:opentrace_parent_span_id],
          nil, # request_summary
          event_type # event_type
        ].freeze)
      ensure
        Fiber[:opentrace_logging] = nil
      end
    rescue StandardError
      # Never raise to the host app
    end

    # Push a raw entry (e.g. :request array) directly to the client queue.
    # Used by Rails subscribers to bypass OpenTrace.log overhead.
    def client_enqueue_raw(entry)
      return unless enabled?
      client.enqueue(entry)
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
    #
    #   OpenTrace.trace("stripe.charge") do
    #     Stripe::Charge.create(amount: 2000, currency: "usd")
    #   end
    #
    #   OpenTrace.trace("pdf.generate", resource: "Invoice") do |span|
    #     span.set_tag(:pages, 42)
    #     generate_invoice_pdf(order)
    #   end
    #
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
        # OpenTrace setup failed — run block without tracing
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
    # Breadcrumbs are attached to error payloads for debugging.
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

    # Get the current request's breadcrumbs (for testing/debugging)
    def current_breadcrumbs
      Fiber[:opentrace_breadcrumbs]&.to_a || []
    end

    # Capture local variables from a rescue block's binding and attach
    # them to the exception for the next OpenTrace.error() call.
    #
    #   rescue => e
    #     OpenTrace.capture_binding(e, binding)
    #     OpenTrace.error(e)
    #     raise
    #   end
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

    # Resolve context without dup (for capturing in deferred arrays).
    # The frozen/unfrozen Hash is captured by reference; PayloadBuilder
    # will dup it when materializing on the background thread.
    def resolve_context_raw
      case config.context
      when Proc then config.context.call
      when Hash then config.context
      end
    rescue StandardError
      {}
    end

    # Legacy resolve_context kept for backward compat if any external code calls it.
    # Returns a mutable dup safe for the caller to modify.
    def resolve_context
      cached = Fiber[:opentrace_cached_context]
      return cached.dup if cached

      ctx = resolve_context_raw
      result = ctx.is_a?(Hash) ? ctx : {}

      if Fiber[:opentrace_request_id]
        Fiber[:opentrace_cached_context] = result.freeze
        return result.dup
      end

      result.dup
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

      # Record in RequestCollector timeline if present
      collector = Fiber[:opentrace_collector]
      collector&.record_span(operation: @operation, duration_ms: meta[:span_duration_ms])
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
