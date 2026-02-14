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
      @half_open_probe_sent = false
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
            @half_open_probe_sent = true
            true
          else
            false
          end
        when HALF_OPEN
          if @half_open_probe_sent
            false
          else
            @half_open_probe_sent = true
            true
          end
        end
      end
    end

    def record_success
      @mutex.synchronize do
        @failure_count = 0
        @half_open_probe_sent = false
        @state = CLOSED
      end
    end

    def record_failure
      @mutex.synchronize do
        @failure_count += 1
        @last_failure_at = Time.now
        if @state == HALF_OPEN
          @half_open_probe_sent = false
          @state = OPEN
        elsif @failure_count >= @failure_threshold
          @state = OPEN
        end
      end
    end

    def reset!
      @mutex.synchronize do
        @state = CLOSED
        @failure_count = 0
        @last_failure_at = nil
        @half_open_probe_sent = false
      end
    end
  end
end
