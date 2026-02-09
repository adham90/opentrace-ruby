# frozen_string_literal: true

require "net/http"
require "uri"
require "json"

module OpenTrace
  class Client
    MAX_QUEUE_SIZE = 1000
    PAYLOAD_MAX_BYTES = 32_768 # 32 KB
    POLL_INTERVAL = 0.05 # 50ms

    def initialize(config)
      @config = config
      @queue  = Thread::Queue.new
      @mutex  = Mutex.new
      @thread = nil
    end

    def enqueue(payload)
      return unless @config.enabled?

      # Drop newest if queue is full
      return if @queue.size >= MAX_QUEUE_SIZE

      @queue.push(payload)
      ensure_thread_running
    end

    def shutdown(timeout: 5)
      @queue.close
      @thread&.join(timeout)
    end

    private

    def ensure_thread_running
      return if @thread&.alive?

      @mutex.synchronize do
        return if @thread&.alive?

        @thread = Thread.new { dispatch_loop }
        @thread.abort_on_exception = false
        @thread.report_on_exception = false
      end
    end

    def dispatch_loop
      uri = URI.join(@config.endpoint.chomp("/") + "/", "api/logs")

      loop do
        batch = drain_queue
        break if batch.nil?
        next if batch.empty?

        send_batch(uri, batch)
      end
    rescue Exception # rubocop:disable Lint/RescueException
      # Swallow all errors including thread kill
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
        break if Time.now >= deadline && !batch.empty?
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

    def send_batch(uri, batch)
      # Apply per-payload truncation
      batch = batch.map { |p| fit_payload(p) }.compact
      return if batch.empty?

      json = JSON.generate(batch)

      # If entire batch exceeds limit, split and retry
      if json.bytesize > PAYLOAD_MAX_BYTES
        mid = batch.size / 2
        send_batch(uri, batch[0...mid]) if mid > 0
        send_batch(uri, batch[mid..]) if mid < batch.size
        return
      end

      http = build_http(uri)
      request = Net::HTTP::Post.new(uri.request_uri)
      request["Authorization"] = "Bearer #{@config.api_key}"
      request["Content-Type"]  = "application/json"
      request["User-Agent"]    = "opentrace-ruby/#{OpenTrace::VERSION}"
      request.body = json

      http.request(request)
    rescue StandardError
      # Swallow all network errors silently
    end

    def build_http(uri)
      http = Net::HTTP.new(uri.host, uri.port)
      http.use_ssl = (uri.scheme == "https")
      http.open_timeout = @config.timeout
      http.read_timeout = @config.timeout
      http.write_timeout = @config.timeout
      http
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
