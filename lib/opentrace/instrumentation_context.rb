# frozen_string_literal: true

require_relative "buffer_pool"
require_relative "memory_guard"
require_relative "capture_rules"
require_relative "config"

module OpenTrace
  class InstrumentationContext
    FIBER_KEY = :opentrace_buffer

    class << self
      # ── Setup ──
      #
      # Initializes a capture context for the current Fiber.
      # Called at the start of a request (with env:) or job (with job:).
      #
      # Checks out a RequestBuffer from the global BufferPool, sets it on the
      # current Fiber, and marks the event_type.
      #
      # Returns the buffer (for callers that need it).
      def setup(env: nil, job: nil)
        buf = buffer_pool.checkout
        allocation_bytes = buf.byte_size

        unless memory_guard.allocate(allocation_bytes)
          buffer_pool.checkin(buf)
          return nil
        end

        buf.event_type = if env
                           :http_request
                         elsif job
                           :job_perform
                         end

        Fiber[:opentrace_buffer_allocation_bytes] = allocation_bytes
        Fiber[FIBER_KEY] = buf
        buf
      end

      # ── Teardown ──
      #
      # Finalizes the capture context. Resolves capture level (via CaptureRules
      # if configured), applies MemoryGuard effective level, produces the
      # document, checks the buffer back into the pool, and clears the Fiber
      # local.
      #
      # Returns the document Hash, or nil when capture resolves to :none.
      # The caller is responsible for enqueueing.
      def teardown(status: nil, duration_ms: nil, error: false)
        buf = Fiber[FIBER_KEY]
        return nil unless buf

        begin
          # Resolve capture level
          capture_level = resolve_capture_level(
            buf, status: status, duration_ms: duration_ms, error: error
          )

          # Apply memory guard — may downgrade under pressure
          capture_level = memory_guard.effective_level(capture_level)
          return nil if capture_level == :none

          # Build domain overrides from capture rules (if configured)
          domain_overrides = configured_domain_overrides

          # Produce the document. Timeline is omitted unless the user opted in
          # via config.timeline (default false).
          doc = buf.to_document(
            capture_level: capture_level,
            domain_overrides: domain_overrides,
            include_timeline: timeline_enabled?
          )
          doc[:duration_ms] = duration_ms if duration_ms
          doc[:error] = true if error
          doc[:pending_explains] = Fiber[:opentrace_pending_explains] if Fiber[:opentrace_pending_explains]

          doc
        ensure
          allocation_bytes = Fiber[:opentrace_buffer_allocation_bytes].to_i
          memory_guard.release(allocation_bytes) if allocation_bytes.positive?

          # Return buffer to pool and clear Fiber local
          buffer_pool.checkin(buf)
          Fiber[FIBER_KEY] = nil
          Fiber[:opentrace_buffer_allocation_bytes] = nil
        end
      end

      # ── Convenience accessors ──

      # Returns the current Fiber's RequestBuffer, or nil.
      def current_buffer
        Fiber[FIBER_KEY]
      end

      # Returns true if there is a buffer on the current Fiber.
      def active?
        !Fiber[FIBER_KEY].nil?
      end

      # ── Singleton resources (lazy-initialized) ──

      def buffer_pool
        cfg = active_config
        @buffer_pool ||= BufferPool.new(
          max_buffer_bytes: cfg.max_buffer_bytes,
          max_audit_events: cfg.audit_max_events_per_request
        )
      end

      def memory_guard
        cfg = active_config
        @memory_guard ||= MemoryGuard.new(max_total_bytes: cfg.max_total_buffer_bytes)
      end

      def configure!(config)
        @config = config
        @buffer_pool = nil
        @memory_guard = nil
        @capture_rules = config.capture_rules_block ? CaptureRules.new(&config.capture_rules_block) : nil
      end

      # Reset singletons (for testing).
      def reset!
        @config = nil
        @buffer_pool = nil
        @memory_guard = nil
        @capture_rules = nil
      end

      # Optional capture rules instance. Set via configuration.
      attr_accessor :capture_rules

      private

      # Resolve the capture level for this request/job.
      # If CaptureRules are configured, use them; otherwise default to :standard.
      def resolve_capture_level(buf, status:, duration_ms:, error:)
        rules = capture_rules
        base_level = configured_capture_depth

        unless rules
          return base_level
        end

        # CaptureRules.resolve expects a Rack env for path matching.
        # For HTTP requests the middleware will have stored env data on the
        # buffer; for jobs we pass a minimal hash.
        env = if buf.event_type == :http_request
                { "PATH_INFO" => buf.request_path || "/" }
              else
                { "PATH_INFO" => "/" }
              end

        rules.resolve(
          env,
          base_level: base_level,
          status: status,
          duration_ms: duration_ms,
          error: error
        )
      end

      def configured_capture_depth
        level = active_config.capture_depth.to_s.downcase.to_sym
        CaptureRules::LEVELS.include?(level) ? level : :standard
      rescue StandardError
        :standard
      end

      def timeline_enabled?
        !!active_config.timeline
      rescue StandardError
        false
      end

      def configured_domain_overrides
        cfg = active_config
        {
          email_capture: cfg.email_capture,
          sql_capture: cfg.sql_capture,
          http_capture: cfg.http_capture,
          audit_capture: cfg.audit_capture,
          request_capture: cfg.request_capture
        }.compact
      rescue StandardError
        {}
      end

      def active_config
        @config || (OpenTrace.respond_to?(:config) ? OpenTrace.config : Config.new)
      end
    end
  end
end
