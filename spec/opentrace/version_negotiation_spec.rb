# frozen_string_literal: true

RSpec.describe "Version negotiation" do
  let(:config) do
    OpenTrace::Config.new.tap do |c|
      c.endpoint = "https://opentrace.test"
      c.api_key = "test-key"
      c.service = "test-svc"
      c.timeout = 1.0
      c.enabled = true
      c.batch_size = 50
      c.flush_interval = 0.2
      c.compression = false
    end
  end

  subject(:client) { OpenTrace::Client.new(config) }

  after { client.shutdown(timeout: 2) }

  describe "X-API-Version header" do
    it "sends X-API-Version header with every request" do
      stub_request(:get, "https://opentrace.test/api/version")
        .to_return(status: 200, body: '{"api_version":1,"capabilities":["batch_ingest"]}')
      stub = stub_request(:post, "https://opentrace.test/api/logs")
        .with(headers: { "X-API-Version" => "2" })
        .to_return(status: 201, body: '{"count":1}')

      client.enqueue({ level: "INFO", message: "test" })
      sleep 0.5

      expect(stub).to have_been_requested
    end
  end

  describe "#check_server_compatibility" do
    it "fetches capabilities from /api/version on first dispatch" do
      version_stub = stub_request(:get, "https://opentrace.test/api/version")
        .to_return(status: 200, body: JSON.generate({
          version: "1.5.0",
          api_version: 1,
          min_client_api_version: 1,
          capabilities: ["batch_ingest", "gzip_request", "request_summaries"]
        }))
      stub_request(:post, "https://opentrace.test/api/logs")
        .to_return(status: 201, body: '{"count":1}')

      client.enqueue({ level: "INFO", message: "test" })
      sleep 0.5

      expect(version_stub).to have_been_requested.once
    end

    it "only checks once even after multiple enqueues" do
      version_stub = stub_request(:get, "https://opentrace.test/api/version")
        .to_return(status: 200, body: '{"api_version":1,"capabilities":[]}')
      stub_request(:post, "https://opentrace.test/api/logs")
        .to_return(status: 201, body: '{"count":1}')

      3.times { client.enqueue({ level: "INFO", message: "test" }) }
      sleep 0.8

      expect(version_stub).to have_been_requested.once
    end

    it "handles server without /api/version gracefully" do
      stub_request(:get, "https://opentrace.test/api/version")
        .to_return(status: 404, body: "Not Found")
      stub = stub_request(:post, "https://opentrace.test/api/logs")
        .to_return(status: 201, body: '{"count":1}')

      client.enqueue({ level: "INFO", message: "test" })
      sleep 0.5

      # Should still send logs even though version check returned 404
      expect(stub).to have_been_requested
    end

    it "handles network error on version check gracefully" do
      stub_request(:get, "https://opentrace.test/api/version")
        .to_raise(Errno::ECONNREFUSED)
      stub = stub_request(:post, "https://opentrace.test/api/logs")
        .to_return(status: 201, body: '{"count":1}')

      client.enqueue({ level: "INFO", message: "test" })
      sleep 0.5

      expect(stub).to have_been_requested
    end

    it "warns when server requires newer client version" do
      stub_request(:get, "https://opentrace.test/api/version")
        .to_return(status: 200, body: JSON.generate({
          api_version: 3,
          min_client_api_version: 3,
          capabilities: []
        }))
      stub_request(:post, "https://opentrace.test/api/logs")
        .to_return(status: 201, body: '{"count":1}')

      expect {
        client.enqueue({ level: "INFO", message: "test" })
        sleep 0.5
      }.to output(/Server requires API version >= 3/).to_stderr
    end

    it "warns when server API version is older than client" do
      # Temporarily set a higher client version for this test
      stub_const("OpenTrace::Client::API_VERSION", 3)
      stub_request(:get, "https://opentrace.test/api/version")
        .to_return(status: 200, body: JSON.generate({
          api_version: 1,
          min_client_api_version: 1,
          capabilities: []
        }))
      stub_request(:post, "https://opentrace.test/api/logs")
        .to_return(status: 201, body: '{"count":1}')

      expect {
        client.enqueue({ level: "INFO", message: "test" })
        sleep 0.5
      }.to output(/Server API version \(1\) is older than client \(3\)/).to_stderr
    end
  end

  describe "#supports?" do
    it "returns true for advertised capabilities" do
      stub_request(:get, "https://opentrace.test/api/version")
        .to_return(status: 200, body: JSON.generate({
          api_version: 1,
          capabilities: ["batch_ingest", "gzip_request", "request_summaries"]
        }))
      stub_request(:post, "https://opentrace.test/api/logs")
        .to_return(status: 201, body: '{"count":1}')

      client.enqueue({ level: "INFO", message: "test" })
      sleep 0.5

      expect(client.supports?(:gzip_request)).to be true
      expect(client.supports?(:request_summaries)).to be true
      expect(client.supports?(:batch_ingest)).to be true
    end

    it "returns false for unadvertised capabilities" do
      stub_request(:get, "https://opentrace.test/api/version")
        .to_return(status: 200, body: JSON.generate({
          api_version: 1,
          capabilities: ["batch_ingest"]
        }))
      stub_request(:post, "https://opentrace.test/api/logs")
        .to_return(status: 201, body: '{"count":1}')

      client.enqueue({ level: "INFO", message: "test" })
      sleep 0.5

      expect(client.supports?(:request_summaries)).to be false
    end

    it "returns false when version check failed" do
      stub_request(:get, "https://opentrace.test/api/version")
        .to_raise(Errno::ECONNREFUSED)
      stub_request(:post, "https://opentrace.test/api/logs")
        .to_return(status: 201, body: '{"count":1}')

      client.enqueue({ level: "INFO", message: "test" })
      sleep 0.5

      expect(client.supports?(:anything)).to be_falsey
    end
  end

  describe "#stats_snapshot" do
    it "includes server_capabilities" do
      stub_request(:get, "https://opentrace.test/api/version")
        .to_return(status: 200, body: JSON.generate({
          api_version: 1,
          capabilities: ["batch_ingest", "gzip_request"]
        }))
      stub_request(:post, "https://opentrace.test/api/logs")
        .to_return(status: 201, body: '{"count":1}')

      client.enqueue({ level: "INFO", message: "test" })
      sleep 0.5

      snapshot = client.stats_snapshot
      expect(snapshot[:server_capabilities]).to eq(["batch_ingest", "gzip_request"])
    end
  end
end
