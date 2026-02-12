# frozen_string_literal: true

module OpenTrace
  class CircuitBreaker
    CLOSED    = :closed
    OPEN      = :open
    HALF_OPEN = :half_open

    attr_reader :state

    def initialize(failure_threshold:, recovery_timeout:)
      @failure_threshold = failure_threshold
      @recovery_timeout  = recovery_timeout
      @state             = CLOSED
      @failure_count     = 0
      @last_failure_at   = nil
      @mutex             = Mutex.new
    end

    def allow_request?
      @mutex.synchronize do
        case @state
        when CLOSED
          true
        when OPEN
          if Time.now - @last_failure_at >= @recovery_timeout
            @state = HALF_OPEN
            true
          else
            false
          end
        when HALF_OPEN
          false
        end
      end
    end

    def record_success
      @mutex.synchronize do
        @failure_count = 0
        @state = CLOSED
      end
    end

    def record_failure
      @mutex.synchronize do
        @failure_count += 1
        @last_failure_at = Time.now
        @state = OPEN if @failure_count >= @failure_threshold
      end
    end

    def reset!
      @mutex.synchronize do
        @state = CLOSED
        @failure_count = 0
        @last_failure_at = nil
      end
    end
  end
end
