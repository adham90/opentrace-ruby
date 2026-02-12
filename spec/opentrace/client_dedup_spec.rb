# frozen_string_literal: true

RSpec.describe OpenTrace::Client, "batch deduplication" do
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
      c.retry_base_delay = 0.01
      c.retry_max_delay = 0.05
      c.compression = false # disable compression to simplify header inspection
    end
  end

  subject(:client) { described_class.new(config) }

  after { client.shutdown(timeout: 2) }

  describe "X-Batch-ID header" do
    it "sends X-Batch-ID header with each request" do
      batch_ids = []
      stub_request(:post, "https://opentrace.test/api/logs")
        .to_return do |req|
          batch_ids << req.headers["X-Batch-Id"]
          { status: 201, body: '{"count":1}' }
        end

      client.enqueue({ level: "INFO", message: "test" })
      sleep 0.5

      expect(batch_ids.length).to eq(1)
      expect(batch_ids.first).to match(/\A[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\z/)
    end

    it "uses the same batch ID across retries" do
      batch_ids = []
      call_count = 0
      stub_request(:post, "https://opentrace.test/api/logs")
        .to_return do |req|
          call_count += 1
          batch_ids << req.headers["X-Batch-Id"]
          if call_count <= 2
            { status: 500, body: '{"error":"internal"}' }
          else
            { status: 201, body: '{"count":1}' }
          end
        end

      client.enqueue({ level: "INFO", message: "retry me" })
      sleep 1.0

      # 3 attempts with same batch ID
      expect(batch_ids.length).to eq(3)
      expect(batch_ids.uniq.length).to eq(1)
    end

    it "uses different batch IDs for different batches" do
      batch_ids = []
      stub_request(:post, "https://opentrace.test/api/logs")
        .to_return do |req|
          batch_ids << req.headers["X-Batch-Id"]
          { status: 201, body: '{"count":1}' }
        end

      client.enqueue({ level: "INFO", message: "batch 1" })
      sleep 0.5
      client.enqueue({ level: "INFO", message: "batch 2" })
      sleep 0.5

      expect(batch_ids.length).to eq(2)
      expect(batch_ids.uniq.length).to eq(2)
    end
  end
end
