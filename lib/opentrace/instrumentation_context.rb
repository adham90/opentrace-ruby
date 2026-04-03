# frozen_string_literal: true

require_relative "buffer_pool"
require_relative "memory_guard"
require_relative "capture_rules"

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

        buf.event_type = if env
                           :http_request
                         elsif job
                           :job_perform
                         end

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
      # Returns the document Hash. The caller is responsible for enqueueing.
      def teardown(status: nil, duration_ms: nil, error: false)
        buf = Fiber[FIBER_KEY]
        return nil unless buf

        # Resolve capture level
        capture_level = resolve_capture_level(
          buf, status: status, duration_ms: duration_ms, error: error
        )

        # Apply memory guard — may downgrade under pressure
        capture_level = memory_guard.effective_level(capture_level)

        # Normalize: MemoryGuard returns :none when exceeded, but RequestBuffer
        # only understands :minimal / :standard / :full. Map :none to :minimal.
        capture_level = :minimal if capture_level == :none

        # Build domain overrides from capture rules (if configured)
        domain_overrides = {}

        # Produce the document
        doc = buf.to_document(capture_level: capture_level, domain_overrides: domain_overrides)

        # Return buffer to pool and clear Fiber local
        buffer_pool.checkin(buf)
        Fiber[FIBER_KEY] = nil

        doc
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
        @buffer_pool ||= BufferPool.new
      end

      def memory_guard
        @memory_guard ||= MemoryGuard.new
      end

      # Reset singletons (for testing).
      def reset!
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

        unless rules
          return :standard
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
          base_level: :standard,
          status: status,
          duration_ms: duration_ms,
          error: error
        )
      end
    end
  end
end
