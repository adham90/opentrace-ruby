# frozen_string_literal: true

RSpec.describe OpenTrace::Client, "gzip compression" do
  let(:config) do
    OpenTrace::Config.new.tap do |c|
      c.endpoint = "https://opentrace.test"
      c.api_key = "test-key"
      c.service = "test-svc"
      c.timeout = 1.0
      c.enabled = true
      c.batch_size = 50
      c.flush_interval = 0.2
      c.compression = true
      c.compression_threshold = 1024
    end
  end

  subject(:client) { described_class.new(config) }

  after { client.shutdown(timeout: 2) }

  def decompress_gzip(body)
    gz = Zlib::GzipReader.new(StringIO.new(body))
    gz.read
  ensure
    gz&.close
  end

  describe "when payload exceeds compression threshold" do
    it "sends gzip-compressed body with Content-Encoding header" do
      received_encoding = nil
      received_body = nil

      stub_request(:post, "https://opentrace.test/api/logs")
        .to_return do |req|
          received_encoding = req.headers["Content-Encoding"]
          received_body = req.body
          { status: 201, body: '{"count":1}' }
        end

      # Send enough data to exceed 1KB threshold
      10.times do |i|
        client.enqueue({
          level: "INFO",
          message: "This is a reasonably long log message number #{i} with enough content",
          metadata: { request_id: "req-#{i}", controller: "TestController", action: "index",
                      path: "/test/#{i}", status: 200, duration_ms: 42.5 }
        })
      end
      sleep 0.5

      expect(received_encoding).to eq("gzip")
      # Verify the body is valid gzip
      json = decompress_gzip(received_body)
      batch = JSON.parse(json)
      expect(batch).to be_an(Array)
      expect(batch.first["message"]).to start_with("This is a reasonably long")
    end
  end

  describe "when payload is below compression threshold" do
    it "sends uncompressed body without Content-Encoding header" do
      config.compression_threshold = 100_000 # very high threshold
      small_client = described_class.new(config)

      received_encoding = nil
      stub_request(:post, "https://opentrace.test/api/logs")
        .to_return do |req|
          received_encoding = req.headers["Content-Encoding"]
          { status: 201, body: '{"count":1}' }
        end

      small_client.enqueue({ level: "INFO", message: "tiny" })
      sleep 0.5

      expect(received_encoding).to be_nil
      small_client.shutdown(timeout: 2)
    end
  end

  describe "when compression is disabled" do
    it "sends uncompressed body regardless of size" do
      config.compression = false
      no_compress_client = described_class.new(config)

      received_encoding = nil
      stub_request(:post, "https://opentrace.test/api/logs")
        .to_return do |req|
          received_encoding = req.headers["Content-Encoding"]
          { status: 201, body: '{"count":1}' }
        end

      10.times do |i|
        no_compress_client.enqueue({
          level: "INFO",
          message: "This is a reasonably long log message number #{i} with enough content",
          metadata: { request_id: "req-#{i}", controller: "TestController" }
        })
      end
      sleep 0.5

      expect(received_encoding).to be_nil
      no_compress_client.shutdown(timeout: 2)
    end
  end

  describe "compressed data integrity" do
    it "decompresses to valid JSON matching the original batch" do
      received_body = nil
      stub_request(:post, "https://opentrace.test/api/logs")
        .to_return do |req|
          received_body = req.body
          { status: 201, body: '{"count":1}' }
        end

      messages = 10.times.map { |i| "message-#{i}-with-enough-data-to-exceed-threshold-easily" }
      messages.each do |msg|
        client.enqueue({ level: "INFO", message: msg, metadata: { padding: "x" * 50 } })
      end
      sleep 0.5

      json = decompress_gzip(received_body)
      batch = JSON.parse(json)
      received_messages = batch.map { |item| item["message"] }
      messages.each { |msg| expect(received_messages).to include(msg) }
    end
  end

  describe "config defaults" do
    it "has compression = true by default" do
      expect(OpenTrace::Config.new.compression).to eq(true)
    end

    it "has compression_threshold = 1024 by default" do
      expect(OpenTrace::Config.new.compression_threshold).to eq(1024)
    end
  end
end
