# frozen_string_literal: true

require "net/http"
require "uri"
require "json"

module OpenTrace
  class Client
    MAX_QUEUE_SIZE = 1000
    PAYLOAD_MAX_BYTES = 32_768 # 32 KB

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

      while (payload = next_from_queue)
        begin
          send_payload(uri, payload)
        rescue Exception # rubocop:disable Lint/RescueException
          # Swallow everything - never crash the host app
        end
      end
    rescue Exception # rubocop:disable Lint/RescueException
      # Swallow all errors including thread kill
    end

    def next_from_queue
      @queue.pop
    rescue ClosedQueueError
      nil
    end

    def send_payload(uri, payload)
      json = JSON.generate(payload)

      if json.bytesize > PAYLOAD_MAX_BYTES
        payload = truncate_payload(payload)
        json = JSON.generate(payload)
        return if json.bytesize > PAYLOAD_MAX_BYTES
      end

      http = Net::HTTP.new(uri.host, uri.port)
      http.use_ssl = (uri.scheme == "https")
      http.open_timeout = @config.timeout
      http.read_timeout = @config.timeout
      http.write_timeout = @config.timeout

      request = Net::HTTP::Post.new(uri.request_uri)
      request["Authorization"] = "Bearer #{@config.api_key}"
      request["Content-Type"]  = "application/json"
      request["User-Agent"]    = "opentrace-ruby/#{OpenTrace::VERSION}"
      request.body = json

      http.request(request)
    rescue StandardError
      # Swallow all network errors silently
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
