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

module OpenTrace
  LEVEL_VALUES = { "DEBUG" => 0, "INFO" => 1, "WARN" => 2, "ERROR" => 3, "FATAL" => 4 }.freeze

  # Null object for when OpenTrace is not configured.
  # All methods are no-ops, avoiding nil checks on the hot path.
  class NilClient
    def enqueue(_) = nil
    def shutdown(timeout: 5) = nil
    def queue_size = 0
    def circuit_state = :closed
    def auth_suspended? = false
    def stats_snapshot = { queue_size: 0, circuit_state: :closed, auth_suspended: false }
    def stats = NilStats.new
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
        meta[:error_fingerprint] = compute_error_fingerprint(exception.class.name, cleaned)
      end

      # Capture exception cause chain (max 5 deep)
      if exception.cause
        meta[:exception_causes] = build_cause_chain(exception.cause, depth: 0)
      end

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

    def compute_error_fingerprint(exception_class, backtrace)
      origin = if backtrace.is_a?(Array)
                 backtrace.find { |l| l.include?("app/") || l.include?("lib/") } || backtrace.first
               end
      normalized_origin = origin&.gsub(/:\d+:/, ":") || "unknown"
      Digest::MD5.hexdigest("#{exception_class}||#{normalized_origin}")[0, 12]
    rescue StandardError
      nil
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
end

# Auto-load Rails integration if Rails is present
require_relative "opentrace/rails" if defined?(::Rails::Railtie)
