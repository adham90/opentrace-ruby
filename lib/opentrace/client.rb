# frozen_string_literal: true

require "net/http"
require "uri"
require "json"
require "zlib"
require "stringio"

module OpenTrace
  class Client
    MAX_QUEUE_SIZE = 1000
    PAYLOAD_MAX_BYTES = 32_768 # 32 KB
    POLL_INTERVAL = 0.05 # 50ms
    MAX_RATE_LIMIT_BACKOFF = 60 # Cap Retry-After at 60 seconds

    attr_reader :stats

    def initialize(config)
      @config = config
      @queue  = Thread::Queue.new
      @mutex  = Mutex.new
      @thread = nil
      @pid    = Process.pid
      @circuit_breaker = CircuitBreaker.new(
        failure_threshold: config.circuit_breaker_threshold,
        recovery_timeout: config.circuit_breaker_timeout
      )
      @rate_limit_until = nil
      @auth_suspended = false
      @auth_failure_warned = false
      @stats = Stats.new
    end

    def enqueue(payload)
      return unless @config.enabled?

      if @auth_suspended
        @stats.increment(:dropped_auth_suspended)
        fire_on_drop(1, :auth_suspended)
        return
      end

      reset_after_fork! if forked?

      # Drop newest if queue is full
      if @queue.size >= MAX_QUEUE_SIZE
        @stats.increment(:dropped_queue_full)
        fire_on_drop(1, :queue_full)
        return
      end

      @queue.push(payload)
      @stats.increment(:enqueued)
      ensure_thread_running
    end

    def queue_size
      @queue.size
    end

    def circuit_state
      @circuit_breaker.state
    end

    def auth_suspended?
      @auth_suspended
    end

    def stats_snapshot
      @stats.to_h.merge(
        queue_size: queue_size,
        circuit_state: circuit_state,
        auth_suspended: @auth_suspended
      )
    end

    def shutdown(timeout: 5)
      @queue.close
      @thread&.join(timeout)
    end

    private

    def forked?
      Process.pid != @pid
    end

    def reset_after_fork!
      # After fork, the old thread/queue/mutex from the parent are dead.
      # Re-create everything cleanly in the child process.
      @pid    = Process.pid
      @queue  = Thread::Queue.new
      @mutex  = Mutex.new
      @thread = nil
      @circuit_breaker.reset!
      @rate_limit_until = nil
      @auth_suspended = false
      @auth_failure_warned = false
      @stats = Stats.new
    end

    def ensure_thread_running
      return if @thread&.alive?

      # Use try_lock so we never block the calling thread.
      # If another thread is already spawning the dispatch thread, skip —
      # the next enqueue will see it alive.
      return unless @mutex.try_lock
      begin
        return if @thread&.alive?

        @thread = Thread.new { dispatch_loop }
        @thread.abort_on_exception = false
        @thread.report_on_exception = false
      ensure
        @mutex.unlock
      end
    end

    def dispatch_loop
      @uri = URI.join(@config.endpoint.chomp("/") + "/", "api/logs")

      loop do
        wait_for_rate_limit if rate_limited?

        batch = drain_queue
        break if batch.nil?
        next if batch.empty?

        send_batch(batch)
      end
    rescue Exception # rubocop:disable Lint/RescueException
      # Swallow all errors including thread kill
    end

    def rate_limited?
      @rate_limit_until && Time.now < @rate_limit_until
    end

    def wait_for_rate_limit
      while rate_limited? && !@queue.closed?
        remaining = @rate_limit_until - Time.now
        break if remaining <= 0
        sleep([remaining, 0.5].min)
      end
    end

    def drain_queue
      batch = []
      deadline = Time.now + @config.flush_interval

      loop do
        if batch.empty?
          # Block until first item arrives or timeout
          item = pop_with_timeout(deadline - Time.now)
          return nil if item.nil? && @queue.closed?
          batch << item if item
        else
          # Non-blocking drain up to batch_size
          while batch.size < @config.batch_size
            begin
              item = @queue.pop(true) # non_block = true
              batch << item
            rescue ThreadError
              break # queue empty
            end
          end
        end

        break if batch.size >= @config.batch_size
        break if Time.now >= deadline
        break if @queue.closed?
      end

      batch
    end

    def pop_with_timeout(timeout)
      deadline = Time.now + [timeout, 0].max
      loop do
        begin
          return @queue.pop(true)
        rescue ThreadError
          return nil if Time.now >= deadline || @queue.closed?
          sleep(POLL_INTERVAL)
        end
      end
    rescue ClosedQueueError
      nil
    end

    def send_batch(batch)
      # Circuit breaker: skip if server is known-down
      unless @circuit_breaker.allow_request?
        @stats.increment(:dropped_circuit_open, batch.size)
        fire_on_drop(batch.size, :circuit_open)
        return
      end

      # Disable HTTP tracking for our own calls to prevent infinite recursion
      Fiber[:opentrace_http_tracking_disabled] = true

      # Apply per-payload truncation
      batch = batch.map { |p| fit_payload(p) }.compact
      return if batch.empty?

      json = JSON.generate(batch)

      # If entire batch exceeds limit, split and retry
      if json.bytesize > PAYLOAD_MAX_BYTES
        @stats.increment(:payload_splits)
        mid = batch.size / 2
        send_batch(batch[0...mid]) if mid > 0
        send_batch(batch[mid..]) if mid < batch.size
        return
      end

      response = send_with_retry(json)
      handle_response(response, batch, json.bytesize)
    rescue StandardError
      @circuit_breaker.record_failure
      @stats.increment(:dropped_error, batch.size)
      fire_on_drop(batch.size, :error)
    ensure
      Fiber[:opentrace_http_tracking_disabled] = nil
    end

    def handle_response(response, batch, bytes = 0)
      if response.nil?
        @circuit_breaker.record_failure
        @stats.increment(:dropped_error, batch.size)
        fire_on_drop(batch.size, :error)
        return
      end

      case response
      when Net::HTTPSuccess
        @circuit_breaker.record_success
        @stats.increment(:delivered, batch.size)
        @stats.increment(:batches_sent)
        @stats.increment(:bytes_sent, bytes)
      when Net::HTTPTooManyRequests
        handle_rate_limit(response, batch)
      when Net::HTTPUnauthorized
        handle_auth_failure
      when Net::HTTPServerError
        @circuit_breaker.record_failure
        @stats.increment(:dropped_error, batch.size)
        fire_on_drop(batch.size, :error)
      else
        # Other 4xx — client error, drop batch silently
      end
    end

    def handle_rate_limit(response, batch)
      @stats.increment(:rate_limited)
      retry_after = parse_retry_after(response)
      @rate_limit_until = Time.now + retry_after

      # Re-enqueue batch items if space allows
      batch.each do |payload|
        break if @queue.size >= MAX_QUEUE_SIZE
        @queue.push(payload)
      rescue ClosedQueueError
        break
      end
    end

    def parse_retry_after(response)
      value = response["Retry-After"]&.to_f
      if value && value > 0
        [value, MAX_RATE_LIMIT_BACKOFF].min
      else
        @config.rate_limit_backoff
      end
    end

    def handle_auth_failure
      @stats.increment(:auth_failures)

      unless @auth_failure_warned
        warn "[OpenTrace] Authentication failed (401). Check your api_key configuration. " \
             "Log forwarding is suspended until reconfigured."
        @auth_failure_warned = true
      end

      @auth_suspended = true
    end

    def send_with_retry(json)
      attempts = 0
      max_attempts = @config.max_retries + 1

      loop do
        attempts += 1

        begin
          response = http_post(json)

          return response if response.is_a?(Net::HTTPSuccess)
          return response unless retryable_response?(response)
        rescue StandardError
          # Network errors are retryable
          raise if attempts >= max_attempts
          @stats.increment(:retries)
          sleep(calculate_backoff(attempts))
          next
        end

        break if attempts >= max_attempts

        @stats.increment(:retries)
        sleep(calculate_backoff(attempts))
      end

      response
    end

    def http_post(json)
      http = build_http(@uri)
      request = Net::HTTP::Post.new(@uri.request_uri)
      request["Authorization"] = "Bearer #{@config.api_key}"
      request["Content-Type"]  = "application/json"
      request["User-Agent"]    = "opentrace-ruby/#{OpenTrace::VERSION}"

      if @config.compression && json.bytesize > @config.compression_threshold
        request.body = gzip_compress(json)
        request["Content-Encoding"] = "gzip"
      else
        request.body = json
      end

      http.request(request)
    end

    def retryable_response?(response)
      response.code.to_i >= 500
    end

    def calculate_backoff(attempt)
      base = @config.retry_base_delay * (2**(attempt - 1))
      delay = [base, @config.retry_max_delay].min
      jitter = delay * rand(0.0..0.25)
      delay + jitter
    end

    def build_http(uri)
      http = Net::HTTP.new(uri.host, uri.port)
      http.use_ssl = (uri.scheme == "https")
      http.open_timeout = @config.timeout
      http.read_timeout = @config.timeout
      http.write_timeout = @config.timeout
      http
    end

    def gzip_compress(string)
      io = StringIO.new
      io.set_encoding("BINARY")
      gz = Zlib::GzipWriter.new(io, Zlib::BEST_SPEED)
      gz.write(string)
      gz.close
      io.string
    end

    def fire_on_drop(count, reason)
      @config.on_drop&.call(count, reason)
    rescue StandardError
      # Never let a callback break the client
    end

    def fit_payload(payload)
      json = JSON.generate(payload)
      if json.bytesize > PAYLOAD_MAX_BYTES
        payload = truncate_payload(payload)
        json = JSON.generate(payload)
        return nil if json.bytesize > PAYLOAD_MAX_BYTES
      end
      payload
    rescue StandardError
      nil
    end

    def truncate_payload(payload)
      meta = payload[:metadata]&.dup || {}

      # Truncation priority: remove largest optional fields first
      meta.delete(:backtrace)
      meta.delete(:params)
      meta.delete(:job_arguments)
      meta[:sql] = meta[:sql][0, 200] + "..." if meta[:sql].is_a?(String) && meta[:sql].length > 200
      meta[:exception_message] = meta[:exception_message][0, 200] + "..." if meta[:exception_message].is_a?(String) && meta[:exception_message].length > 200

      payload.merge(metadata: meta)
    end
  end
end
