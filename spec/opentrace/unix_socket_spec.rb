# frozen_string_literal: true

RSpec.describe "Unix Socket Transport" do
  before do
    OpenTrace.reset!
    OpenTrace.configure do |c|
      c.endpoint = "https://opentrace.test"
      c.api_key = "test-key"
      c.service = "test-app"
      c.flush_interval = 0.2
    end
    stub_request(:any, /opentrace\.test/).to_return(status: 200, body: "{}")
  end

  after { OpenTrace.shutdown(timeout: 1) }

  describe "config" do
    it "defaults to :http transport" do
      expect(OpenTrace.config.transport).to eq(:http)
    end

    it "defaults socket_path to /tmp/opentrace.sock" do
      expect(OpenTrace.config.socket_path).to eq("/tmp/opentrace.sock")
    end

    it "accepts :unix_socket transport" do
      OpenTrace.configure do |c|
        c.endpoint = "https://opentrace.test"
        c.api_key = "test-key"
        c.service = "test-app"
        c.transport = :unix_socket
        c.socket_path = "/var/run/opentrace.sock"
      end
      expect(OpenTrace.config.transport).to eq(:unix_socket)
      expect(OpenTrace.config.socket_path).to eq("/var/run/opentrace.sock")
    end
  end

  describe "UnixSocketResponse" do
    let(:response_class) { OpenTrace::Client.const_get(:UnixSocketResponse) }

    it "reports 200 as HTTPSuccess" do
      resp = response_class.new(200)
      expect(resp.is_a?(Net::HTTPSuccess)).to be true
      expect(resp.is_a?(Net::HTTPServerError)).to be false
    end

    it "reports 429 as HTTPTooManyRequests" do
      resp = response_class.new(429)
      expect(resp.is_a?(Net::HTTPTooManyRequests)).to be true
    end

    it "reports 401 as HTTPUnauthorized" do
      resp = response_class.new(401)
      expect(resp.is_a?(Net::HTTPUnauthorized)).to be true
    end

    it "reports 500 as HTTPServerError" do
      resp = response_class.new(500)
      expect(resp.is_a?(Net::HTTPServerError)).to be true
    end

    it "reports 201 as HTTPSuccess" do
      resp = response_class.new(201)
      expect(resp.is_a?(Net::HTTPSuccess)).to be true
    end
  end

  describe "fallback to HTTP" do
    it "falls back to HTTP when socket file does not exist" do
      OpenTrace.configure do |c|
        c.endpoint = "https://opentrace.test"
        c.api_key = "test-key"
        c.service = "test-app"
        c.flush_interval = 0.2
        c.transport = :unix_socket
        c.socket_path = "/tmp/nonexistent_opentrace_test.sock"
      end

      OpenTrace.log("INFO", "test message")
      sleep 0.5

      # Should have fallen back to HTTP successfully
      expect(WebMock).to have_requested(:post, /opentrace\.test/)
    end
  end
end
