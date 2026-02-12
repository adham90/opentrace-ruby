# frozen_string_literal: true

RSpec.describe OpenTrace::Client, "retry and circuit breaker" do
  let(:config) do
    OpenTrace::Config.new.tap do |c|
      c.endpoint = "https://opentrace.test"
      c.api_key = "test-key"
      c.service = "test-svc"
      c.timeout = 1.0
      c.enabled = true
      c.batch_size = 50
      c.flush_interval = 0.2
      c.max_retries = 2
      c.retry_base_delay = 0.01 # fast retries for tests
      c.retry_max_delay = 0.05
      c.circuit_breaker_threshold = 3
      c.circuit_breaker_timeout = 10.0 # long timeout so circuit stays open during tests
    end
  end

  subject(:client) { described_class.new(config) }

  after { client.shutdown(timeout: 2) }

  def parse_batch(req)
    JSON.parse(req.body)
  end

  describe "retry on server errors" do
    it "retries on 500 and succeeds on later attempt" do
      call_count = 0
      stub_request(:post, "https://opentrace.test/api/logs")
        .to_return do |_req|
          call_count += 1
          if call_count <= 2
            { status: 500, body: '{"error":"internal"}' }
          else
            { status: 201, body: '{"count":1}' }
          end
        end

      client.enqueue({ level: "INFO", message: "retry me" })
      sleep 1.0

      # 2 failures + 1 success = 3 attempts
      expect(call_count).to eq(3)
    end

    it "retries on 502 gateway errors" do
      call_count = 0
      stub_request(:post, "https://opentrace.test/api/logs")
        .to_return do |_req|
          call_count += 1
          if call_count == 1
            { status: 502, body: "Bad Gateway" }
          else
            { status: 201, body: '{"count":1}' }
          end
        end

      client.enqueue({ level: "INFO", message: "gateway retry" })
      sleep 1.0

      expect(call_count).to eq(2)
    end

    it "retries on 503 service unavailable" do
      call_count = 0
      stub_request(:post, "https://opentrace.test/api/logs")
        .to_return do |_req|
          call_count += 1
          if call_count == 1
            { status: 503, body: "Service Unavailable" }
          else
            { status: 201, body: '{"count":1}' }
          end
        end

      client.enqueue({ level: "INFO", message: "503 retry" })
      sleep 1.0

      expect(call_count).to eq(2)
    end

    it "retries on 429 too many requests" do
      call_count = 0
      stub_request(:post, "https://opentrace.test/api/logs")
        .to_return do |_req|
          call_count += 1
          if call_count == 1
            { status: 429, body: "rate limited" }
          else
            { status: 201, body: '{"count":1}' }
          end
        end

      client.enqueue({ level: "INFO", message: "rate limited" })
      sleep 1.0

      expect(call_count).to eq(2)
    end

    it "stops retrying after max_retries exhausted" do
      call_count = 0
      stub_request(:post, "https://opentrace.test/api/logs")
        .to_return do |_req|
          call_count += 1
          { status: 500, body: '{"error":"internal"}' }
        end

      client.enqueue({ level: "INFO", message: "always fails" })
      sleep 1.5

      # max_retries=2 → 3 total attempts
      expect(call_count).to eq(3)
    end
  end

  describe "no retry on client errors" do
    it "does not retry on 400 bad request" do
      call_count = 0
      stub_request(:post, "https://opentrace.test/api/logs")
        .to_return do |_req|
          call_count += 1
          { status: 400, body: '{"error":"bad request"}' }
        end

      client.enqueue({ level: "INFO", message: "bad" })
      sleep 0.5

      expect(call_count).to eq(1)
    end

    it "does not retry on 401 unauthorized" do
      call_count = 0
      stub_request(:post, "https://opentrace.test/api/logs")
        .to_return do |_req|
          call_count += 1
          { status: 401, body: '{"error":"unauthorized"}' }
        end

      client.enqueue({ level: "INFO", message: "unauth" })
      sleep 0.5

      expect(call_count).to eq(1)
    end

    it "does not retry on 413 payload too large" do
      call_count = 0
      stub_request(:post, "https://opentrace.test/api/logs")
        .to_return do |_req|
          call_count += 1
          { status: 413, body: '{"error":"too large"}' }
        end

      client.enqueue({ level: "INFO", message: "big" })
      sleep 0.5

      expect(call_count).to eq(1)
    end
  end

  describe "retry on network errors" do
    it "retries on connection refused then succeeds" do
      call_count = 0
      stub_request(:post, "https://opentrace.test/api/logs")
        .to_return do |_req|
          call_count += 1
          if call_count == 1
            raise Errno::ECONNREFUSED
          else
            { status: 201, body: '{"count":1}' }
          end
        end

      client.enqueue({ level: "INFO", message: "conn refused" })
      sleep 1.0

      expect(call_count).to eq(2)
    end

    it "retries on timeout then succeeds" do
      call_count = 0
      stub_request(:post, "https://opentrace.test/api/logs")
        .to_return do |_req|
          call_count += 1
          if call_count == 1
            raise Net::ReadTimeout
          else
            { status: 201, body: '{"count":1}' }
          end
        end

      client.enqueue({ level: "INFO", message: "timeout" })
      sleep 1.0

      expect(call_count).to eq(2)
    end

    it "gives up after max_retries network errors" do
      call_count = 0
      stub_request(:post, "https://opentrace.test/api/logs")
        .to_return do |_req|
          call_count += 1
          raise Errno::ECONNREFUSED
        end

      expect {
        client.enqueue({ level: "INFO", message: "always refused" })
        sleep 1.5
      }.not_to raise_error

      expect(call_count).to eq(3) # 1 + 2 retries
    end
  end

  describe "circuit breaker integration" do
    it "opens circuit after consecutive failures" do
      call_count = 0
      stub_request(:post, "https://opentrace.test/api/logs")
        .to_return do |_req|
          call_count += 1
          { status: 500, body: '{"error":"internal"}' }
        end

      # Each batch triggers 3 attempts (1 + 2 retries), recording 1 failure to circuit breaker.
      # With threshold=3, need 3 failed batches to open circuit.
      5.times do |i|
        client.enqueue({ level: "INFO", message: "fail-#{i}" })
        sleep 0.6 # wait for batch to process
      end

      # First 3 batches: each does 3 attempts = 9 calls, then circuit opens
      # 4th and 5th batches: circuit is open, 0 calls
      # Total: 9 calls
      expect(call_count).to eq(9)
    end

    it "recovers after circuit breaker timeout" do
      # Use a short recovery timeout for this test
      recovery_config = OpenTrace::Config.new.tap do |c|
        c.endpoint = "https://opentrace.test"
        c.api_key = "test-key"
        c.service = "test-svc"
        c.timeout = 1.0
        c.enabled = true
        c.batch_size = 50
        c.flush_interval = 0.2
        c.max_retries = 2
        c.retry_base_delay = 0.01
        c.retry_max_delay = 0.05
        c.circuit_breaker_threshold = 3
        c.circuit_breaker_timeout = 1.0
      end
      recovery_client = described_class.new(recovery_config)

      call_count = 0
      stub_request(:post, "https://opentrace.test/api/logs")
        .to_return do |_req|
          call_count += 1
          if call_count <= 9 # first 3 batches × 3 attempts each
            { status: 500, body: '{"error":"internal"}' }
          else
            { status: 201, body: '{"count":1}' }
          end
        end

      # Trigger 3 failed batches to open the circuit
      3.times do |i|
        recovery_client.enqueue({ level: "INFO", message: "fail-#{i}" })
        sleep 0.6
      end

      # Circuit should be open now — wait for recovery timeout
      sleep 1.2

      # This batch should be the probe (half-open) and succeed
      recovery_client.enqueue({ level: "INFO", message: "recover" })
      sleep 1.0

      # 9 failed + 1 probe success = 10
      expect(call_count).to eq(10)

      recovery_client.shutdown(timeout: 2)
    end
  end

  describe "config defaults" do
    it "has max_retries = 2 by default" do
      expect(OpenTrace::Config.new.max_retries).to eq(2)
    end

    it "has retry_base_delay = 0.1 by default" do
      expect(OpenTrace::Config.new.retry_base_delay).to eq(0.1)
    end

    it "has retry_max_delay = 2.0 by default" do
      expect(OpenTrace::Config.new.retry_max_delay).to eq(2.0)
    end

    it "has circuit_breaker_threshold = 5 by default" do
      expect(OpenTrace::Config.new.circuit_breaker_threshold).to eq(5)
    end

    it "has circuit_breaker_timeout = 30 by default" do
      expect(OpenTrace::Config.new.circuit_breaker_timeout).to eq(30)
    end
  end

  describe "preserves existing behavior" do
    it "still sends successfully on first attempt" do
      stub = stub_request(:post, "https://opentrace.test/api/logs")
        .to_return(status: 201, body: '{"count":1}')

      client.enqueue({ level: "INFO", message: "works first try" })
      sleep 0.5

      expect(stub).to have_been_requested.once
    end

    it "still swallows all errors without crashing" do
      stub_request(:post, "https://opentrace.test/api/logs")
        .to_raise(Errno::ECONNREFUSED)

      expect {
        client.enqueue({ level: "INFO", message: "test" })
        sleep 1.5
      }.not_to raise_error
    end
  end
end
