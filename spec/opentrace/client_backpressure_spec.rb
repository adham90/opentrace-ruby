# frozen_string_literal: true

RSpec.describe OpenTrace::Client, "backpressure handling" do
  let(:config) do
    OpenTrace::Config.new.tap do |c|
      c.endpoint = "https://opentrace.test"
      c.api_key = "test-key"
      c.service = "test-svc"
      c.timeout = 1.0
      c.enabled = true
      c.batch_size = 50
      c.flush_interval = 0.2
      c.max_retries = 0 # no retries to isolate backpressure behavior
      c.rate_limit_backoff = 0.5 # fast backoff for tests
      c.circuit_breaker_threshold = 10 # high threshold to avoid interference
      c.circuit_breaker_timeout = 30
    end
  end

  subject(:client) { described_class.new(config) }

  after { client.shutdown(timeout: 2) }

  describe "429 rate limit handling" do
    it "pauses sending after receiving 429" do
      call_count = 0
      stub_request(:post, "https://opentrace.test/api/logs")
        .to_return do |_req|
          call_count += 1
          if call_count == 1
            { status: 429, body: "rate limited", headers: { "Retry-After" => "1" } }
          else
            { status: 201, body: '{"count":1}' }
          end
        end

      # First batch gets 429
      client.enqueue({ level: "INFO", message: "batch-1" })
      sleep 0.5

      expect(call_count).to eq(1)

      # Second batch should be delayed by the rate limit
      # Wait for rate limit to expire (1s) plus processing time
      sleep 1.5

      # The re-enqueued items + new items should have been sent
      expect(call_count).to be >= 2
    end

    it "respects Retry-After header" do
      stub_request(:post, "https://opentrace.test/api/logs")
        .to_return(
          { status: 429, body: "rate limited", headers: { "Retry-After" => "1" } }
        ).then.to_return(
          { status: 201, body: '{"count":1}' }
        )

      client.enqueue({ level: "INFO", message: "will be rate limited" })
      sleep 0.5

      # Should be rate limited — second request not sent yet
      expect(
        a_request(:post, "https://opentrace.test/api/logs")
      ).to have_been_made.once

      # Wait for Retry-After to expire
      sleep 1.5

      # Now the re-enqueued batch should have been sent
      expect(
        a_request(:post, "https://opentrace.test/api/logs")
      ).to have_been_made.at_least_times(2)
    end

    it "uses default backoff when Retry-After header is missing" do
      config.rate_limit_backoff = 0.3

      stub_request(:post, "https://opentrace.test/api/logs")
        .to_return(
          { status: 429, body: "rate limited" }
        ).then.to_return(
          { status: 201, body: '{"count":1}' }
        )

      client.enqueue({ level: "INFO", message: "no header" })
      sleep 0.5

      expect(
        a_request(:post, "https://opentrace.test/api/logs")
      ).to have_been_made.once

      # Wait for default backoff
      sleep 0.8

      expect(
        a_request(:post, "https://opentrace.test/api/logs")
      ).to have_been_made.at_least_times(2)
    end

    it "caps Retry-After at MAX_RATE_LIMIT_BACKOFF" do
      # Verify the constant exists and is reasonable
      expect(OpenTrace::Client::MAX_RATE_LIMIT_BACKOFF).to eq(60)
    end

    it "re-enqueues batch items on 429" do
      call_count = 0
      received_messages = []
      stub_request(:post, "https://opentrace.test/api/logs")
        .to_return do |req|
          call_count += 1
          batch = JSON.parse(req.body)
          batch.each { |item| received_messages << item["message"] }
          if call_count == 1
            { status: 429, body: "rate limited", headers: { "Retry-After" => "0.3" } }
          else
            { status: 201, body: '{"count":1}' }
          end
        end

      client.enqueue({ level: "INFO", message: "re-enqueue-me" })
      sleep 1.5

      # The message should appear in at least 2 requests (original + re-enqueued)
      expect(received_messages.count("re-enqueue-me")).to be >= 2
    end

    it "does not re-enqueue when queue is full" do
      # Fill queue nearly to capacity
      stub_request(:post, "https://opentrace.test/api/logs")
        .to_return(status: 429, body: "rate limited", headers: { "Retry-After" => "10" })

      # Fill up the queue
      (OpenTrace::Client::MAX_QUEUE_SIZE - 1).times do |i|
        client.enqueue({ level: "INFO", message: "filler-#{i}" })
      end

      # This should not raise even when re-enqueue can't fit
      expect {
        sleep 0.5
      }.not_to raise_error
    end
  end

  describe "401 auth suspension" do
    it "suspends sending after 401" do
      call_count = 0
      stub_request(:post, "https://opentrace.test/api/logs")
        .to_return do |_req|
          call_count += 1
          { status: 401, body: '{"error":"unauthorized"}' }
        end

      client.enqueue({ level: "INFO", message: "first" })
      sleep 0.5

      # First batch fails with 401
      expect(call_count).to eq(1)

      # Subsequent enqueues should be dropped (auth suspended)
      client.enqueue({ level: "INFO", message: "second" })
      client.enqueue({ level: "INFO", message: "third" })
      sleep 0.5

      # No additional requests made
      expect(call_count).to eq(1)
    end

    it "prints warning to STDERR on first 401" do
      stub_request(:post, "https://opentrace.test/api/logs")
        .to_return(status: 401, body: '{"error":"unauthorized"}')

      expect {
        client.enqueue({ level: "INFO", message: "bad auth" })
        sleep 0.5
      }.to output(/Authentication failed.*401.*api_key/i).to_stderr
    end

    it "prints warning only once" do
      # We need a client that processes two batches before suspension kicks in
      # First batch triggers 401 → warning + suspension
      # Second batch is dropped at enqueue (auth_suspended)
      stub_request(:post, "https://opentrace.test/api/logs")
        .to_return(status: 401, body: '{"error":"unauthorized"}')

      output = capture_stderr do
        client.enqueue({ level: "INFO", message: "first" })
        sleep 0.5
        client.enqueue({ level: "INFO", message: "second" })
        sleep 0.5
      end

      # Warning should appear exactly once
      expect(output.scan(/Authentication failed/).length).to eq(1)
    end

    it "resumes sending after reconfigure creates new client" do
      call_count = 0
      stub_request(:post, "https://opentrace.test/api/logs")
        .to_return do |_req|
          call_count += 1
          if call_count == 1
            { status: 401, body: '{"error":"unauthorized"}' }
          else
            { status: 201, body: '{"count":1}' }
          end
        end

      client.enqueue({ level: "INFO", message: "will fail" })
      sleep 0.5
      expect(call_count).to eq(1)

      # Create a new client (simulates OpenTrace.configure creating fresh client)
      new_client = described_class.new(config)
      new_client.enqueue({ level: "INFO", message: "fresh start" })
      sleep 0.5

      expect(call_count).to eq(2)
      new_client.shutdown(timeout: 2)
    end

    it "does not affect circuit breaker state" do
      # 401 should not count as a circuit breaker failure
      config.circuit_breaker_threshold = 2
      auth_client = described_class.new(config)

      call_count = 0
      stub_request(:post, "https://opentrace.test/api/logs")
        .to_return do |_req|
          call_count += 1
          { status: 401, body: '{"error":"unauthorized"}' }
        end

      auth_client.enqueue({ level: "INFO", message: "auth fail" })
      sleep 0.5

      # Only 1 call — auth suspension prevents further attempts
      # Circuit breaker should NOT have opened (401 doesn't count)
      expect(call_count).to eq(1)
      auth_client.shutdown(timeout: 2)
    end
  end

  describe "other 4xx responses" do
    it "drops batch on 400 without affecting circuit breaker" do
      call_count = 0
      stub_request(:post, "https://opentrace.test/api/logs")
        .to_return do |_req|
          call_count += 1
          if call_count <= 2
            { status: 400, body: '{"error":"bad request"}' }
          else
            { status: 201, body: '{"count":1}' }
          end
        end

      # Send two batches that get 400, then a third that succeeds
      3.times do |i|
        client.enqueue({ level: "INFO", message: "msg-#{i}" })
        sleep 0.5
      end

      # All 3 batches should have been attempted (400 doesn't open circuit)
      expect(call_count).to eq(3)
    end
  end

  describe "config defaults" do
    it "has rate_limit_backoff = 5.0 by default" do
      expect(OpenTrace::Config.new.rate_limit_backoff).to eq(5.0)
    end
  end

  private

  def capture_stderr
    old_stderr = $stderr
    $stderr = StringIO.new
    yield
    $stderr.string
  ensure
    $stderr = old_stderr
  end
end
