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

      payload = { timestamp: Time.now.utc.iso8601, level: "INFO", message: "test" }
      client.enqueue(payload)

      # Give background thread time to process
      sleep 0.5

      expect(stub).to have_been_requested
    end

    it "includes the correct payload as JSON" do
      stub = stub_request(:post, "https://opentrace.test/api/logs")
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

      expect(stub).to have_been_requested
      expect(
        a_request(:post, "https://opentrace.test/api/logs")
          .with { |req| JSON.parse(req.body)["level"] == "ERROR" }
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

      # Fill the queue by blocking dispatch temporarily
      # We test this indirectly - enqueue more than MAX_QUEUE_SIZE
      # and verify no error is raised
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
  end

  describe "#shutdown" do
    it "processes remaining queue items before stopping" do
      stub = stub_request(:post, "https://opentrace.test/api/logs")
        .to_return(status: 201, body: '{"count":1}')

      3.times { client.enqueue({ level: "INFO", message: "test" }) }
      client.shutdown(timeout: 5)

      expect(stub).to have_been_requested.at_least_once
    end
  end
end
