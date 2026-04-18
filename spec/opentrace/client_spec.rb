# frozen_string_literal: true

RSpec.describe OpenTrace::Client do
  let(:config) do
    OpenTrace::Config.new.tap do |c|
      c.endpoint = "https://opentrace.test"
      c.api_key = "test-key"
      c.service = "test-svc"
      c.timeout = 1.0
      c.enabled = true
      c.batch_size = 50
      c.flush_interval = 0.2 # fast flush for tests
      c.compression = false  # disable in tests for predictable body parsing
    end
  end

  subject(:client) { described_class.new(config) }

  after { client.shutdown(timeout: 2) }

  # Helper: parse batch body (always an array now)
  def parse_batch(req)
    JSON.parse(req.body)
  end

  describe "#enqueue" do
    it "sends a POST request to /api/logs" do
      stub = stub_request(:post, "https://opentrace.test/api/logs")
        .with(
          headers: {
            "Authorization" => "Bearer test-key",
            "Content-Type" => "application/json",
            "User-Agent" => "opentrace-ruby/#{OpenTrace::VERSION}"
          }
        )
        .to_return(status: 201, body: '{"count":1}')

      client.enqueue({ timestamp: Time.now.utc.iso8601, level: "INFO", message: "test" })
      sleep 0.5

      expect(stub).to have_been_requested
    end

    it "sends payload as a JSON array (batch)" do
      stub_request(:post, "https://opentrace.test/api/logs")
        .to_return(status: 201, body: '{"count":1}')

      client.enqueue({ level: "INFO", message: "batch test" })
      sleep 0.5

      expect(
        a_request(:post, "https://opentrace.test/api/logs")
          .with { |req|
            body = parse_batch(req)
            body.is_a?(Array) && body.first["message"] == "batch test"
          }
      ).to have_been_made
    end

    it "batches multiple payloads together" do
      config.batch_size = 3
      config.flush_interval = 5.0 # long interval — batch_size triggers flush
      batch_client = described_class.new(config)

      stub_request(:post, "https://opentrace.test/api/logs")
        .to_return(status: 201, body: '{"count":3}')

      3.times { |i| batch_client.enqueue({ level: "INFO", message: "msg-#{i}" }) }
      sleep 0.5

      expect(
        a_request(:post, "https://opentrace.test/api/logs")
          .with { |req|
            body = parse_batch(req)
            body.is_a?(Array) && body.size == 3
          }
      ).to have_been_made

      batch_client.shutdown(timeout: 2)
    end

    it "flushes at interval even if batch not full" do
      config.batch_size = 100
      config.flush_interval = 0.3
      interval_client = described_class.new(config)

      stub_request(:post, "https://opentrace.test/api/logs")
        .to_return(status: 201, body: '{"count":1}')

      interval_client.enqueue({ level: "INFO", message: "flush me" })
      sleep 0.8

      expect(
        a_request(:post, "https://opentrace.test/api/logs")
          .with { |req| parse_batch(req).first["message"] == "flush me" }
      ).to have_been_made

      interval_client.shutdown(timeout: 2)
    end

    it "does not enqueue when disabled" do
      config.enabled = false
      stub = stub_request(:post, "https://opentrace.test/api/logs")

      client.enqueue({ level: "INFO", message: "test" })
      sleep 0.5

      expect(stub).not_to have_been_requested
    end

    it "drops messages when queue is full" do
      stub_request(:post, "https://opentrace.test/api/logs")
        .to_return(status: 201, body: '{"count":1}')

      expect {
        (OpenTrace::Client::MAX_QUEUE_SIZE + 100).times do |i|
          client.enqueue({ level: "INFO", message: "msg #{i}" })
        end
      }.not_to raise_error
    end

    it "swallows network errors silently" do
      stub_request(:post, "https://opentrace.test/api/logs")
        .to_raise(Errno::ECONNREFUSED)

      expect {
        client.enqueue({ level: "ERROR", message: "test" })
        sleep 0.5
      }.not_to raise_error
    end

    it "swallows timeout errors silently" do
      stub_request(:post, "https://opentrace.test/api/logs")
        .to_timeout

      expect {
        client.enqueue({ level: "ERROR", message: "test" })
        sleep 0.5
      }.not_to raise_error
    end

    it "swallows DNS resolution errors silently" do
      stub_request(:post, "https://opentrace.test/api/logs")
        .to_raise(SocketError.new("getaddrinfo: nodename nor servname provided"))

      expect {
        client.enqueue({ level: "ERROR", message: "test" })
        sleep 0.5
      }.not_to raise_error
    end

    it "swallows SSL errors silently" do
      stub_request(:post, "https://opentrace.test/api/logs")
        .to_raise(OpenSSL::SSL::SSLError.new("SSL_connect returned=1"))

      expect {
        client.enqueue({ level: "ERROR", message: "test" })
        sleep 0.5
      }.not_to raise_error
    end

    it "continues processing after a network error" do
      call_count = 0
      stub_request(:post, "https://opentrace.test/api/logs")
        .to_return { |_req|
          call_count += 1
          if call_count == 1
            raise Errno::ECONNREFUSED
          else
            { status: 201, body: '{"count":1}' }
          end
        }

      client.enqueue({ level: "ERROR", message: "will fail" })
      sleep 0.5
      client.enqueue({ level: "INFO", message: "will succeed" })
      sleep 0.5

      expect(call_count).to be >= 2
    end

    it "truncates oversized payloads instead of dropping" do
      config.max_payload_bytes = 4096 # low limit to force truncation
      truncate_client = described_class.new(config)

      stub_request(:post, "https://opentrace.test/api/logs")
        .to_return(status: 201, body: '{"count":1}')

      # Build a payload that exceeds 4KB but fits after truncation
      truncate_client.enqueue({
        ts: Time.now.utc.strftime("%Y-%m-%dT%H:%M:%S.%6NZ"),
        level: "error",
        service: "test-svc",
        message: "big error",
        body: {
          context: {
            params: { data: "x" * 3_000 },
            exception_class: "RuntimeError",
          },
          timeline: (1..50).map { |i| { type: "sql", name: "query_#{i}", offset_ms: i } }
        }
      })
      sleep 1

      expect(
        a_request(:post, "https://opentrace.test/api/logs")
          .with { |req|
            batch = parse_batch(req)
            body = batch.first["body"]
            batch.first["message"] == "big error" &&
              !body.key?("timeline") && # timeline removed by truncation
              !body.dig("context", "params") # params removed by truncation
          }
      ).to have_been_made

      truncate_client.shutdown(timeout: 2)
    end

    it "drops truly massive payloads that can't be truncated" do
      stub = stub_request(:post, "https://opentrace.test/api/logs")
        .to_return(status: 201, body: '{"count":1}')

      client.enqueue({ level: "INFO", message: "x" * 300_000, metadata: {} })
      sleep 0.5

      expect(stub).not_to have_been_requested
    end

    it "respects custom max_payload_bytes configuration" do
      config.max_payload_bytes = 1024 # 1KB for this test
      small_client = described_class.new(config)

      stub = stub_request(:post, "https://opentrace.test/api/logs")
        .to_return(status: 201, body: '{"count":1}')

      small_client.enqueue({ level: "INFO", message: "x" * 2000, metadata: {} })
      sleep 0.5

      # Should be dropped since message > 1KB and can't be truncated
      expect(stub).not_to have_been_requested
      small_client.shutdown(timeout: 2)
    end

    it "passes normal payloads through unchanged" do
      stub_request(:post, "https://opentrace.test/api/logs")
        .to_return(status: 201, body: '{"count":1}')

      client.enqueue({
        level: "INFO",
        message: "small",
        metadata: { backtrace: ["line1", "line2"], params: { a: 1 } }
      })
      sleep 0.5

      expect(
        a_request(:post, "https://opentrace.test/api/logs")
          .with { |req|
            meta = parse_batch(req).first["metadata"]
            meta["backtrace"] == ["line1", "line2"] && meta["params"] == { "a" => 1 }
          }
      ).to have_been_made
    end

    it "handles server 500 responses without crashing" do
      stub_request(:post, "https://opentrace.test/api/logs")
        .to_return(status: 500, body: '{"error":"internal"}')

      expect {
        client.enqueue({ level: "INFO", message: "test" })
        sleep 0.5
      }.not_to raise_error
    end

    it "handles server 401 responses without crashing" do
      stub_request(:post, "https://opentrace.test/api/logs")
        .to_return(status: 401, body: '{"error":"unauthorized"}')

      expect {
        client.enqueue({ level: "INFO", message: "test" })
        sleep 0.5
      }.not_to raise_error
    end

    it "uses HTTPS when endpoint scheme is https" do
      stub = stub_request(:post, "https://opentrace.test/api/logs")
        .to_return(status: 201, body: '{"count":1}')

      client.enqueue({ level: "INFO", message: "test" })
      sleep 0.5

      expect(stub).to have_been_requested
    end

    it "uses HTTP when endpoint scheme is http" do
      config.endpoint = "http://opentrace.test"
      http_client = described_class.new(config)

      stub = stub_request(:post, "http://opentrace.test/api/logs")
        .to_return(status: 201, body: '{"count":1}')

      http_client.enqueue({ level: "INFO", message: "test" })
      sleep 0.5
      http_client.shutdown(timeout: 2)

      expect(stub).to have_been_requested
    end
  end

  describe "thread behavior" do
    it "does not start a thread at initialization" do
      fresh_client = described_class.new(config)
      sleep 0.2
      fresh_client.shutdown(timeout: 1)
    end

    it "starts the thread lazily on first enqueue" do
      stub_request(:post, "https://opentrace.test/api/logs")
        .to_return(status: 201, body: '{"count":1}')

      client.enqueue({ level: "INFO", message: "first" })
      sleep 0.5

      expect(
        a_request(:post, "https://opentrace.test/api/logs")
      ).to have_been_made
    end

    it "processes multiple messages" do
      received_messages = []
      stub_request(:post, "https://opentrace.test/api/logs")
        .to_return { |req|
          batch = JSON.parse(req.body)
          batch.each { |item| received_messages << item["message"] }
          { status: 201, body: '{"count":1}' }
        }

      5.times { |i| client.enqueue({ level: "INFO", message: "msg-#{i}" }) }
      sleep 1.0

      expect(received_messages.sort).to eq(%w[msg-0 msg-1 msg-2 msg-3 msg-4])
    end
  end

  describe "#shutdown" do
    it "flushes remaining queue items before stopping" do
      stub = stub_request(:post, "https://opentrace.test/api/logs")
        .to_return(status: 201, body: '{"count":1}')

      3.times { client.enqueue({ level: "INFO", message: "test" }) }
      client.shutdown(timeout: 5)

      expect(stub).to have_been_requested.at_least_once
    end

    it "can be called multiple times without error" do
      expect {
        client.shutdown(timeout: 1)
        client.shutdown(timeout: 1)
      }.not_to raise_error
    end
  end

  describe "fork safety" do
    it "detects a forked process and re-initializes" do
      stub_request(:post, "https://opentrace.test/api/logs")
        .to_return(status: 201, body: '{"count":1}')

      # Enqueue one message to start the thread
      client.enqueue({ level: "INFO", message: "parent" })
      sleep 0.3

      # Simulate fork by changing the pid
      old_queue = client.instance_variable_get(:@queue)
      allow(Process).to receive(:pid).and_return(Process.pid + 1)

      client.enqueue({ level: "INFO", message: "child" })
      new_queue = client.instance_variable_get(:@queue)

      # Queue should be a new instance after fork detection
      expect(new_queue).not_to equal(old_queue)
      expect(client.instance_variable_get(:@pid)).to eq(Process.pid)

      sleep 0.5
    end

    it "does not re-initialize when pid has not changed" do
      stub_request(:post, "https://opentrace.test/api/logs")
        .to_return(status: 201, body: '{"count":1}')

      client.enqueue({ level: "INFO", message: "first" })
      queue_after_first = client.instance_variable_get(:@queue)

      client.enqueue({ level: "INFO", message: "second" })
      queue_after_second = client.instance_variable_get(:@queue)

      expect(queue_after_second).to equal(queue_after_first)
      sleep 0.3
    end
  end

  describe "non-blocking enqueue" do
    it "uses try_lock so enqueue never blocks on mutex" do
      stub_request(:post, "https://opentrace.test/api/logs")
        .to_return(status: 201, body: '{"count":1}')

      # Enqueue from multiple threads concurrently — none should hang
      threads = 10.times.map do |i|
        Thread.new { client.enqueue({ level: "INFO", message: "thread-#{i}" }) }
      end
      threads.each { |t| t.join(5) }

      # Verify no threads timed out (join returned nil means timeout)
      expect(threads.all?(&:alive?)).to eq(false)
      sleep 0.5
    end
  end

  describe "config defaults" do
    it "has batch_size = 50 by default" do
      expect(OpenTrace::Config.new.batch_size).to eq(50)
    end

    it "has flush_interval = 5.0 by default" do
      expect(OpenTrace::Config.new.flush_interval).to eq(5.0)
    end
  end
end
