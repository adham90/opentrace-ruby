# frozen_string_literal: true

require "net/http"
require "uri"
require "json"
require "zlib"
require "stringio"
require "securerandom"

module OpenTrace
  class Client
    MAX_QUEUE_SIZE = 1000
    PAYLOAD_MAX_BYTES = 262_144 # 256 KB (default; use config.max_payload_bytes to override)
    MAX_RATE_LIMIT_BACKOFF = 60 # Cap Retry-After at 60 seconds
    API_VERSION = 1

    attr_reader :stats

    def initialize(config, sampler: nil)
      @config = config
      @sampler = sampler
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
      @compatibility_checked = false
      @server_capabilities = nil
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
        auth_suspended: @auth_suspended,
        server_capabilities: @server_capabilities
      )
    end

    def supports?(capability)
      @server_capabilities&.include?(capability.to_s)
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
      # After fork, the old thread/queue/mutex/connection from the parent are dead.
      # Re-create everything cleanly in the child process.
      @pid    = Process.pid
      @queue  = Thread::Queue.new
      @mutex  = Mutex.new
      @thread = nil
      @http   = nil # Parent's connection is unusable after fork
      @circuit_breaker.reset!
      @rate_limit_until = nil
      @auth_suspended = false
      @auth_failure_warned = false
      @stats = Stats.new
      @compatibility_checked = false
      @server_capabilities = nil
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
      check_server_compatibility

      loop do
        wait_for_rate_limit if rate_limited?

        batch = drain_queue
        break if batch.nil?
        next if batch.empty?

        send_batch(batch)

        # Adjust backpressure based on queue depth
        if @sampler
          queue_pct = @queue.size.to_f / MAX_QUEUE_SIZE
          if queue_pct > 0.75
            @sampler.increase_backpressure!
          elsif queue_pct < 0.25
            @sampler.decrease_backpressure!
          end
        end
      end
    rescue Exception # rubocop:disable Lint/RescueException
      # Swallow all errors including thread kill
    ensure
      close_http
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
      if timeout <= 0
        # Deadline already passed — still try a non-blocking pop in case
        # items arrived while we were busy (e.g. during version check).
        @queue.pop(true)
      else
        @queue.pop(timeout: timeout)
      end
    rescue ThreadError, ClosedQueueError
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

      # Materialize deferred entries + apply before_send filter + truncate
      batch = batch.filter_map do |item|
        payload = PayloadBuilder.materialize(item, @config)
        next nil unless payload
        if @config.before_send
          payload = @config.before_send.call(payload) rescue payload
          unless payload
            @stats.increment(:dropped_filtered)
            next nil
          end
        end
        # PII scrubbing (runs on background thread)
        if @config.pii_scrubbing && payload[:metadata]
          active_patterns = build_pii_patterns
          PiiScrubber.scrub!(payload[:metadata], patterns: active_patterns)
        end

        fit_payload(payload)
      end
      return if batch.empty?

      json = JSON.generate(batch)

      # If entire batch exceeds limit, split and retry
      if json.bytesize > @config.max_payload_bytes
        @stats.increment(:payload_splits)
        mid = batch.size / 2
        send_batch(batch[0...mid]) if mid > 0
        send_batch(batch[mid..]) if mid < batch.size
        return
      end

      response = if @config.transport == :unix_socket
                   unix_socket_send(json)
                 else
                   send_with_retry(json)
                 end
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
        @config.after_send&.call(batch.size, bytes) rescue nil
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
      batch_id = SecureRandom.uuid
      attempts = 0
      max_attempts = @config.max_retries + 1

      loop do
        attempts += 1

        begin
          response = http_post(json, batch_id: batch_id)

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

    def http_post(json, batch_id: nil)
      request = Net::HTTP::Post.new(@uri.request_uri)
      request["Authorization"] = "Bearer #{@config.api_key}"
      request["Content-Type"]  = "application/json"
      request["User-Agent"]    = "opentrace-ruby/#{OpenTrace::VERSION}"
      request["X-API-Version"] = API_VERSION.to_s
      request["X-Batch-ID"]    = batch_id if batch_id

      if @config.compression && json.bytesize > @config.compression_threshold
        request.body = gzip_compress(json)
        request["Content-Encoding"] = "gzip"
      else
        request.body = json
      end

      persistent_http.request(request)
    rescue IOError, Errno::EPIPE, Errno::ECONNRESET, Net::OpenTimeout => _e
      # Connection went stale — reset and retry once
      close_http
      persistent_http.request(request)
    end

    def unix_socket_send(json)
      payload = if @config.compression && json.bytesize > @config.compression_threshold
                  gzip_compress(json)
                else
                  json
                end

      socket = UNIXSocket.new(@config.socket_path)
      # Protocol: 4-byte big-endian length prefix + payload
      socket.write([payload.bytesize].pack("N"))
      socket.write(payload)
      socket.flush

      # Read 4-byte status code response
      response_data = socket.read(4)
      status = response_data&.unpack1("N") || 500
      socket.close

      UnixSocketResponse.new(status)
    rescue Errno::ECONNREFUSED, Errno::ENOENT, Errno::ENOTSOCK
      # Socket not available — fall back to HTTP
      send_with_retry(json)
    rescue StandardError
      nil
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

    # Returns a persistent Net::HTTP connection, creating one if needed.
    # Only called from the dispatch thread — no synchronization needed.
    def persistent_http
      return @http if @http&.started?

      @http = Net::HTTP.new(@uri.host, @uri.port)
      @http.use_ssl = (@uri.scheme == "https")
      @http.open_timeout = @config.timeout
      @http.read_timeout = @config.timeout
      @http.write_timeout = @config.timeout
      @http.keep_alive_timeout = 30
      @http.start
      @http
    end

    def close_http
      @http&.finish
    rescue IOError
      # Already closed
    ensure
      @http = nil
    end

    def gzip_compress(string)
      io = StringIO.new
      io.set_encoding("BINARY")
      gz = Zlib::GzipWriter.new(io, Zlib::BEST_SPEED)
      gz.write(string)
      gz.close
      io.string
    end

    def build_pii_patterns
      patterns = PiiScrubber::PATTERNS.dup
      # Remove disabled patterns
      if @config.pii_disabled_patterns
        @config.pii_disabled_patterns.each { |name| patterns.delete(name) }
      end
      result = patterns.values
      # Add custom patterns
      if @config.pii_patterns
        result.concat(@config.pii_patterns)
      end
      result
    rescue StandardError
      PiiScrubber::PATTERNS.values
    end

    def fire_on_drop(count, reason)
      @config.on_drop&.call(count, reason)
    rescue StandardError
      # Never let a callback break the client
    end

    def fit_payload(payload)
      json = JSON.generate(payload)
      if json.bytesize > @config.max_payload_bytes
        payload = truncate_payload(payload)
        json = JSON.generate(payload)
        return nil if json.bytesize > @config.max_payload_bytes
      end
      payload
    rescue StandardError
      nil
    end

    def check_server_compatibility
      return if @compatibility_checked

      uri = URI.join(@config.endpoint.chomp("/") + "/", "api/version")
      response = http_get(uri)

      if response.is_a?(Net::HTTPSuccess)
        info = JSON.parse(response.body)
        server_api_version = info["api_version"]
        min_client_version = info["min_client_api_version"]

        if min_client_version && API_VERSION < min_client_version
          warn "[OpenTrace] Server requires API version >= #{min_client_version}, " \
               "but this client supports version #{API_VERSION}. " \
               "Please upgrade the opentrace gem. Log forwarding may not work correctly."
        end

        if server_api_version && server_api_version < API_VERSION
          warn "[OpenTrace] Server API version (#{server_api_version}) is older than " \
               "client (#{API_VERSION}). Some features may not be available."
        end

        @server_capabilities = info.fetch("capabilities", [])
      end

      @compatibility_checked = true
    rescue Exception # rubocop:disable Lint/RescueException
      # Server might not support /api/version yet — that's fine.
      # Broad rescue: this is best-effort and must never kill the dispatch loop.
      @compatibility_checked = true
    end

    # One-shot GET for version check. Uses a throwaway connection
    # so a failure doesn't poison the persistent connection.
    def http_get(uri)
      http = Net::HTTP.new(uri.host, uri.port)
      http.use_ssl = (uri.scheme == "https")
      http.open_timeout = @config.timeout
      http.read_timeout = @config.timeout
      http.write_timeout = @config.timeout
      request = Net::HTTP::Get.new(uri.request_uri)
      request["User-Agent"] = "opentrace-ruby/#{OpenTrace::VERSION}"
      request["Authorization"] = "Bearer #{@config.api_key}"
      http.request(request)
    end

    # Adapts a numeric status code from Unix socket into Net::HTTP response duck type
    UnixSocketResponse = Struct.new(:code) do
      def is_a?(klass)
        c = code.to_i
        case klass.name
        when "Net::HTTPSuccess"          then c >= 200 && c < 300
        when "Net::HTTPTooManyRequests"  then c == 429
        when "Net::HTTPUnauthorized"     then c == 401
        when "Net::HTTPServerError"      then c >= 500 && c < 600
        else super
        end
      end
    end

    def truncate_payload(payload)
      meta = payload[:metadata]&.dup || {}

      # Truncation priority: remove largest optional fields first
      meta.delete(:backtrace)
      meta.delete(:params)
      meta.delete(:job_arguments)
      meta[:sql] = meta[:sql][0, 200] + "..." if meta[:sql].is_a?(String) && meta[:sql].length > 200
      meta[:exception_message] = meta[:exception_message][0, 200] + "..." if meta[:exception_message].is_a?(String) && meta[:exception_message].length > 200

      result = payload.merge(metadata: meta)

      # Remove timeline from request_summary (can be very large)
      if result[:request_summary]
        result[:request_summary] = result[:request_summary].dup
        result[:request_summary].delete(:timeline)
      end

      result
    end
  end
end
