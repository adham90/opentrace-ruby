# frozen_string_literal: true

RSpec.describe OpenTrace::Client, "delivery stats" do
  let(:config) do
    OpenTrace::Config.new.tap do |c|
      c.endpoint = "https://opentrace.test"
      c.api_key = "test-key"
      c.service = "test-svc"
      c.timeout = 1.0
      c.enabled = true
      c.batch_size = 50
      c.flush_interval = 0.2
      c.max_retries = 0 # no retries to isolate stats behavior
      c.circuit_breaker_threshold = 10
      c.circuit_breaker_timeout = 30
    end
  end

  subject(:client) { described_class.new(config) }

  after { client.shutdown(timeout: 2) }

  describe "enqueue stats" do
    it "increments enqueued on successful enqueue" do
      stub_request(:post, "https://opentrace.test/api/logs")
        .to_return(status: 201, body: '{"count":1}')

      3.times { client.enqueue({ level: "INFO", message: "test" }) }
      sleep 0.5

      expect(client.stats.get(:enqueued)).to eq(3)
    end

    it "increments dropped_queue_full when queue is full" do
      stub_request(:post, "https://opentrace.test/api/logs")
        .to_return(status: 201, body: '{"count":1}')

      # Fill the queue
      OpenTrace::Client::MAX_QUEUE_SIZE.times do |i|
        client.enqueue({ level: "INFO", message: "fill-#{i}" })
      end

      # This one should be dropped
      client.enqueue({ level: "INFO", message: "overflow" })

      expect(client.stats.get(:dropped_queue_full)).to eq(1)
    end

    it "increments dropped_auth_suspended when auth is suspended" do
      stub_request(:post, "https://opentrace.test/api/logs")
        .to_return(status: 401, body: '{"error":"unauthorized"}')

      client.enqueue({ level: "INFO", message: "trigger auth fail" })
      sleep 0.5

      # Now auth is suspended — next enqueue should be dropped
      client.enqueue({ level: "INFO", message: "dropped" })

      expect(client.stats.get(:dropped_auth_suspended)).to eq(1)
    end
  end

  describe "delivery stats" do
    it "increments delivered and batches_sent on success" do
      stub_request(:post, "https://opentrace.test/api/logs")
        .to_return(status: 201, body: '{"count":1}')

      2.times { client.enqueue({ level: "INFO", message: "test" }) }
      sleep 0.5

      expect(client.stats.get(:delivered)).to eq(2)
      expect(client.stats.get(:batches_sent)).to eq(1)
    end

    it "tracks bytes_sent on success" do
      stub_request(:post, "https://opentrace.test/api/logs")
        .to_return(status: 201, body: '{"count":1}')

      client.enqueue({ level: "INFO", message: "test" })
      sleep 0.5

      expect(client.stats.get(:bytes_sent)).to be > 0
    end
  end

  describe "error stats" do
    it "increments dropped_error on server 500" do
      stub_request(:post, "https://opentrace.test/api/logs")
        .to_return(status: 500, body: '{"error":"internal"}')

      client.enqueue({ level: "INFO", message: "will fail" })
      sleep 0.5

      expect(client.stats.get(:dropped_error)).to be >= 1
    end

    it "increments dropped_error on network error" do
      stub_request(:post, "https://opentrace.test/api/logs")
        .to_raise(Errno::ECONNREFUSED)

      client.enqueue({ level: "INFO", message: "conn refused" })
      sleep 0.5

      expect(client.stats.get(:dropped_error)).to be >= 1
    end

    it "increments dropped_error on nil response" do
      stub_request(:post, "https://opentrace.test/api/logs")
        .to_return(status: 500, body: '{"error":"internal"}')

      client.enqueue({ level: "INFO", message: "nil response" })
      sleep 0.5

      expect(client.stats.get(:dropped_error)).to be >= 1
    end
  end

  describe "rate limit stats" do
    it "increments rate_limited on 429" do
      stub_request(:post, "https://opentrace.test/api/logs")
        .to_return(
          { status: 429, body: "rate limited", headers: { "Retry-After" => "0.3" } }
        ).then.to_return(
          { status: 201, body: '{"count":1}' }
        )

      client.enqueue({ level: "INFO", message: "rate limited" })
      sleep 1.0

      expect(client.stats.get(:rate_limited)).to eq(1)
    end
  end

  describe "auth failure stats" do
    it "increments auth_failures on 401" do
      stub_request(:post, "https://opentrace.test/api/logs")
        .to_return(status: 401, body: '{"error":"unauthorized"}')

      expect {
        client.enqueue({ level: "INFO", message: "bad auth" })
        sleep 0.5
      }.to output(/Authentication failed/).to_stderr

      expect(client.stats.get(:auth_failures)).to eq(1)
    end
  end

  describe "retry stats" do
    it "increments retries on retryable failures" do
      config.max_retries = 2

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

      retry_client = described_class.new(config.tap { |c| c.retry_base_delay = 0.01; c.retry_max_delay = 0.05 })
      retry_client.enqueue({ level: "INFO", message: "retry me" })
      sleep 1.0

      expect(retry_client.stats.get(:retries)).to eq(2)
      retry_client.shutdown(timeout: 2)
    end
  end

  describe "circuit breaker stats" do
    it "increments dropped_circuit_open when circuit is open" do
      config.circuit_breaker_threshold = 1
      config.max_retries = 0
      cb_client = described_class.new(config)

      stub_request(:post, "https://opentrace.test/api/logs")
        .to_return(status: 500, body: '{"error":"internal"}')

      # First batch fails and opens circuit
      cb_client.enqueue({ level: "INFO", message: "fail" })
      sleep 0.5

      # Second batch should be dropped by circuit breaker
      cb_client.enqueue({ level: "INFO", message: "circuit open" })
      sleep 0.5

      expect(cb_client.stats.get(:dropped_circuit_open)).to be >= 1
      cb_client.shutdown(timeout: 2)
    end
  end

  describe "#stats_snapshot" do
    it "includes all counters plus live data" do
      stub_request(:post, "https://opentrace.test/api/logs")
        .to_return(status: 201, body: '{"count":1}')

      snapshot = client.stats_snapshot

      expect(snapshot).to have_key(:enqueued)
      expect(snapshot).to have_key(:delivered)
      expect(snapshot).to have_key(:queue_size)
      expect(snapshot).to have_key(:circuit_state)
      expect(snapshot).to have_key(:auth_suspended)
      expect(snapshot).to have_key(:uptime_seconds)
    end

    it "reflects current queue size" do
      stub_request(:post, "https://opentrace.test/api/logs")
        .to_return(status: 201, body: '{"count":1}')

      expect(client.stats_snapshot[:queue_size]).to eq(0)
    end

    it "reflects circuit state" do
      expect(client.stats_snapshot[:circuit_state]).to eq(:closed)
    end

    it "reflects auth_suspended state" do
      expect(client.stats_snapshot[:auth_suspended]).to eq(false)
    end
  end

  describe "on_drop callback" do
    it "fires callback when queue is full" do
      drop_events = []
      config.on_drop = ->(count, reason) { drop_events << [count, reason] }

      stub_request(:post, "https://opentrace.test/api/logs")
        .to_return(status: 201, body: '{"count":1}')

      OpenTrace::Client::MAX_QUEUE_SIZE.times do |i|
        client.enqueue({ level: "INFO", message: "fill-#{i}" })
      end
      client.enqueue({ level: "INFO", message: "overflow" })

      expect(drop_events).to include([1, :queue_full])
    end

    it "fires callback when auth is suspended" do
      drop_events = []
      config.on_drop = ->(count, reason) { drop_events << [count, reason] }

      stub_request(:post, "https://opentrace.test/api/logs")
        .to_return(status: 401, body: '{"error":"unauthorized"}')

      client.enqueue({ level: "INFO", message: "trigger" })
      sleep 0.5

      client.enqueue({ level: "INFO", message: "dropped" })

      expect(drop_events).to include([1, :auth_suspended])
    end

    it "fires callback on server error" do
      drop_events = []
      config.on_drop = ->(count, reason) { drop_events << [count, reason] }

      stub_request(:post, "https://opentrace.test/api/logs")
        .to_return(status: 500, body: '{"error":"internal"}')

      client.enqueue({ level: "INFO", message: "server error" })
      sleep 0.5

      expect(drop_events.any? { |_, reason| reason == :error }).to be true
    end

    it "swallows callback exceptions" do
      config.on_drop = ->(_count, _reason) { raise "callback boom" }

      stub_request(:post, "https://opentrace.test/api/logs")
        .to_return(status: 201, body: '{"count":1}')

      # Fill queue to trigger on_drop
      OpenTrace::Client::MAX_QUEUE_SIZE.times do |i|
        client.enqueue({ level: "INFO", message: "fill-#{i}" })
      end

      expect {
        client.enqueue({ level: "INFO", message: "overflow" })
      }.not_to raise_error
    end
  end
end
