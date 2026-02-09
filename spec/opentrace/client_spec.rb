# frozen_string_literal: true

RSpec.describe OpenTrace::Client do
  let(:config) do
    OpenTrace::Config.new.tap do |c|
      c.endpoint = "https://opentrace.test"
      c.api_key = "test-key"
      c.service = "test-svc"
      c.timeout = 1.0
      c.enabled = true
    end
  end

  subject(:client) { described_class.new(config) }

  after { client.shutdown(timeout: 2) }

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

    it "includes the correct payload as JSON" do
      stub_request(:post, "https://opentrace.test/api/logs")
        .to_return(status: 201, body: '{"count":1}')

      payload = {
        timestamp: "2026-01-01T00:00:00Z",
        level: "ERROR",
        service: "billing",
        message: "something broke",
        metadata: { user_id: 42 }
      }
      client.enqueue(payload)
      sleep 0.5

      expect(
        a_request(:post, "https://opentrace.test/api/logs")
          .with { |req|
            body = JSON.parse(req.body)
            body["level"] == "ERROR" &&
              body["message"] == "something broke" &&
              body["metadata"]["user_id"] == 42
          }
      ).to have_been_made
    end

    it "does not enqueue when disabled" do
      config.enabled = false
      stub = stub_request(:post, "https://opentrace.test/api/logs")

      client.enqueue({ level: "INFO", message: "test" })
      sleep 0.3

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
      sleep 0.3
      client.enqueue({ level: "INFO", message: "will succeed" })
      sleep 0.5

      expect(call_count).to be >= 2
    end

    it "truncates oversized payloads instead of dropping" do
      stub = stub_request(:post, "https://opentrace.test/api/logs")
        .to_return(status: 201, body: '{"count":1}')

      # Large backtrace + params that push over 32KB
      huge_backtrace = (1..500).map { |i| "app/models/order.rb:#{i}:in `method_#{i}'" }
      client.enqueue({
        level: "ERROR",
        message: "big error",
        metadata: {
          backtrace: huge_backtrace,
          params: { data: "x" * 20_000 },
          exception_class: "RuntimeError",
          exception_message: "should survive truncation"
        }
      })
      sleep 0.5

      expect(
        a_request(:post, "https://opentrace.test/api/logs")
          .with { |req|
            body = JSON.parse(req.body)
            meta = body["metadata"]
            body["message"] == "big error" &&
              !meta.key?("backtrace") &&
              !meta.key?("params") &&
              meta["exception_class"] == "RuntimeError"
          }
      ).to have_been_made
    end

    it "drops truly massive payloads that can't be truncated" do
      stub = stub_request(:post, "https://opentrace.test/api/logs")
        .to_return(status: 201, body: '{"count":1}')

      # 40KB message — can't be truncated by metadata trimming
      client.enqueue({ level: "INFO", message: "x" * 40_000, metadata: {} })
      sleep 0.5

      expect(stub).not_to have_been_requested
    end

    it "passes normal payloads through unchanged" do
      stub = stub_request(:post, "https://opentrace.test/api/logs")
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
            meta = JSON.parse(req.body)["metadata"]
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
      # No way to inspect @thread directly, but we can verify no requests are made
      sleep 0.2
      fresh_client.shutdown(timeout: 1)
    end

    it "starts the thread lazily on first enqueue" do
      stub_request(:post, "https://opentrace.test/api/logs")
        .to_return(status: 201, body: '{"count":1}')

      client.enqueue({ level: "INFO", message: "first" })
      sleep 0.3

      expect(
        a_request(:post, "https://opentrace.test/api/logs")
      ).to have_been_made
    end

    it "processes multiple messages in order" do
      received_messages = []
      stub_request(:post, "https://opentrace.test/api/logs")
        .to_return { |req|
          received_messages << JSON.parse(req.body)["message"]
          { status: 201, body: '{"count":1}' }
        }

      5.times { |i| client.enqueue({ level: "INFO", message: "msg-#{i}" }) }
      sleep 1.0

      expect(received_messages).to eq(%w[msg-0 msg-1 msg-2 msg-3 msg-4])
    end
  end

  describe "#shutdown" do
    it "processes remaining queue items before stopping" do
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
end
