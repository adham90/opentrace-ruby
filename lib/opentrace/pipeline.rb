# frozen_string_literal: true

require "net/http"
require "uri"
require "json"
require "zlib"
require "stringio"
require "securerandom"
require "socket"

module OpenTrace
  # Multi-worker dispatch pipeline that processes batches in parallel.
  # Each worker thread has its own HTTP connection and processes batches independently.
  #
  # Why threads instead of Ractors:
  # - Ruby's GVL is released during I/O (HTTP send) -- threads get true parallelism
  # - Ractors are still experimental and most gems aren't Ractor-safe
  # - The bottleneck is I/O (HTTP round-trips), not CPU (serialization)
  class Pipeline
    DEFAULT_WORKERS = 2
    MAX_WORKERS = 8

    attr_reader :worker_count

    def initialize(config, worker_count: DEFAULT_WORKERS)
      @config = config
      @worker_count = [[worker_count, 1].max, MAX_WORKERS].min
      @queue = Queue.new  # Thread::Queue for distributing batches to workers
      @workers = []
      @running = false
      @mutex = Mutex.new
      @stats = PipelineStats.new
    end

    # Start the worker pool
    def start
      @mutex.synchronize do
        return if @running
        @running = true
        @workers = @worker_count.times.map { |i| spawn_worker(i) }
      end
    end

    # Submit a batch of raw entries for processing
    # Each batch is: [raw_entry1, raw_entry2, ...]
    def submit(batch)
      return unless @running
      @queue.push(batch)
      @stats.increment(:batches_submitted)
    end

    # Graceful shutdown -- process remaining batches then stop
    def stop(timeout: 5)
      @mutex.synchronize do
        return unless @running
        @running = false
        @worker_count.times { @queue.push(:shutdown) }
      end
      deadline = Time.now + timeout
      @workers.each do |w|
        remaining = deadline - Time.now
        w.join([remaining, 0].max) if remaining > 0
      end
      @workers = []
    end

    def running?
      @running
    end

    def stats
      @stats.to_h
    end

    private

    def spawn_worker(id)
      Thread.new do
        Thread.current.name = "opentrace-pipeline-#{id}"
        Thread.current.abort_on_exception = false
        Thread.current.report_on_exception = false

        http = nil
        uri = URI.join(@config.endpoint.chomp("/") + "/", "api/logs")

        loop do
          batch = @queue.pop
          break if batch == :shutdown

          begin
            # Stage 1: Materialize entries
            payloads = batch.filter_map do |item|
              PayloadBuilder.materialize(item, @config)
            end
            next if payloads.empty?

            # Stage 2: Serialize (MessagePack or JSON)
            encoded, content_type = Serializer.encode(payloads, format: @config.serialization_format)

            # Stage 3: Compress
            body = if @config.compression && encoded.bytesize > @config.compression_threshold
                     gzip_compress(encoded)
                   else
                     encoded
                   end
            compressed = body != encoded

            # Stage 4: Send (HTTP or Unix socket)
            Fiber[:opentrace_http_tracking_disabled] = true
            begin
              if @config.transport == :unix_socket
                unix_socket_send(body, payloads.size)
              else
                http ||= build_http(uri)
                request = build_request(uri, body, content_type, compressed)
                response = http.request(request)

                if response.is_a?(Net::HTTPSuccess)
                  @stats.increment(:delivered, payloads.size)
                  @stats.increment(:bytes_sent, body.bytesize)
                  @on_success&.call(payloads.size, body.bytesize)
                elsif response.code.to_i == 401
                  @stats.increment(:failed, payloads.size)
                  @on_failure&.call(payloads.size, :auth)
                else
                  @stats.increment(:failed, payloads.size)
                  @on_failure&.call(payloads.size, :error)
                  http&.finish rescue nil
                  http = nil
                end
              end
            ensure
              Fiber[:opentrace_http_tracking_disabled] = nil
            end

          rescue IOError, SystemCallError, OpenSSL::SSL::SSLError, Timeout::Error, Net::ProtocolError => e
            @stats.increment(:failed, batch.size)
            @on_failure&.call(batch.size, :error)
            http&.finish rescue nil
            http = nil
          rescue StandardError => e
            @stats.increment(:errors)
          end
        end

        http&.finish rescue nil
      end
    end

    def build_http(uri)
      http = Net::HTTP.new(uri.host, uri.port)
      http.use_ssl = (uri.scheme == "https")
      http.open_timeout = @config.timeout
      http.read_timeout = @config.timeout
      http.write_timeout = @config.timeout
      http.keep_alive_timeout = 30
      http.start
      http
    end

    def build_request(uri, body, content_type, compressed)
      request = Net::HTTP::Post.new(uri.request_uri)
      request["Authorization"] = "Bearer #{@config.api_key}"
      request["Content-Type"] = content_type
      request["User-Agent"] = "opentrace-ruby/#{OpenTrace::VERSION}"
      request["X-API-Version"] = Client::API_VERSION.to_s
      request["X-Batch-ID"] = SecureRandom.uuid
      request["Content-Encoding"] = "gzip" if compressed
      request.body = body
      request
    end

    def gzip_compress(string)
      io = StringIO.new
      io.set_encoding("BINARY")
      gz = Zlib::GzipWriter.new(io, Zlib::BEST_SPEED)
      gz.write(string)
      gz.close
      io.string
    end

    # Send payload via Unix socket (same-machine transport, ~100x faster than HTTP).
    # Protocol: 4-byte big-endian length prefix + payload bytes.
    def unix_socket_send(body, count)
      socket = UNIXSocket.new(@config.socket_path)
      socket.write([body.bytesize].pack("N"))
      socket.write(body)
      socket.flush

      # Read 4-byte status code response with timeout
      if IO.select([socket], nil, nil, 5)
        response_data = socket.read(4)
        status = response_data&.unpack1("N") || 500
      else
        status = 500
      end
      socket.close

      if status >= 200 && status < 300
        @stats.increment(:delivered, count)
        @stats.increment(:bytes_sent, body.bytesize)
        @on_success&.call(count, body.bytesize)
      else
        @stats.increment(:failed, count)
        @on_failure&.call(count, :error)
      end
    rescue Errno::ECONNREFUSED, Errno::ENOENT, Errno::ENOTSOCK => e
      # Socket not available — count as failure
      @stats.increment(:failed, count)
      @on_failure&.call(count, :error)
    rescue StandardError
      @stats.increment(:errors)
    end
  end

  # Thread-safe stats counter for the pipeline
  class PipelineStats
    def initialize
      @counters = Hash.new(0)
      @mutex = Mutex.new
    end

    def increment(key, amount = 1)
      @mutex.synchronize { @counters[key] += amount }
    end

    def get(key)
      @mutex.synchronize { @counters[key] }
    end

    def to_h
      @mutex.synchronize { @counters.dup }
    end

    def reset!
      @mutex.synchronize { @counters.clear }
    end
  end
end
