# frozen_string_literal: true

require "spec_helper"
require "opentrace/pipeline"
require "opentrace/serializer"

RSpec.describe OpenTrace::Pipeline do
  let(:config) { OpenTrace.config }

  before do
    OpenTrace.reset!
    OpenTrace.configure do |c|
      c.endpoint = "http://opentrace.test"
      c.api_key = "test-key"
      c.service = "test"
      c.environment = "test"
      c.serialization_format = :json
      c.compression = false
      c.min_level = :debug
    end
    WebMock.reset!
    stub_request(:post, "http://opentrace.test/api/logs")
      .to_return(status: 201, body: '{"count": 1}')
  end

  after do
    OpenTrace.reset!
  end

  # Build a simple log entry array matching the format from OpenTrace.log
  def make_entry(message = "test message", level = "INFO")
    [
      Time.now.to_f,   # timestamp
      level,           # level
      message,         # message
      {},              # metadata
      {},              # context
      nil,             # request_id
      nil,             # trace_id
      nil,             # span_id
      nil,             # parent_span_id
      nil,             # request_summary
      nil              # event_type
    ]
  end

  describe "#initialize" do
    it "defaults to 2 workers" do
      pipeline = described_class.new(config)
      expect(pipeline.worker_count).to eq(2)
    end

    it "accepts a custom worker count" do
      pipeline = described_class.new(config, worker_count: 4)
      expect(pipeline.worker_count).to eq(4)
    end

    it "clamps worker count to minimum of 1" do
      pipeline = described_class.new(config, worker_count: 0)
      expect(pipeline.worker_count).to eq(1)

      pipeline2 = described_class.new(config, worker_count: -5)
      expect(pipeline2.worker_count).to eq(1)
    end

    it "caps worker count at MAX_WORKERS (8)" do
      pipeline = described_class.new(config, worker_count: 20)
      expect(pipeline.worker_count).to eq(8)
    end
  end

  describe "#start" do
    it "starts the specified number of worker threads" do
      pipeline = described_class.new(config, worker_count: 3)
      pipeline.start

      # Give threads a moment to start
      sleep 0.05

      worker_threads = Thread.list.select { |t| t.name&.start_with?("opentrace-pipeline-") }
      expect(worker_threads.size).to eq(3)

      pipeline.stop(timeout: 2)
    end

    it "marks the pipeline as running" do
      pipeline = described_class.new(config)
      expect(pipeline.running?).to be false

      pipeline.start
      expect(pipeline.running?).to be true

      pipeline.stop(timeout: 2)
    end

    it "is idempotent -- calling start twice does not double workers" do
      pipeline = described_class.new(config, worker_count: 2)
      pipeline.start
      pipeline.start

      sleep 0.05

      worker_threads = Thread.list.select { |t| t.name&.start_with?("opentrace-pipeline-") }
      expect(worker_threads.size).to eq(2)

      pipeline.stop(timeout: 2)
    end
  end

  describe "#submit" do
    it "enqueues a batch for processing" do
      pipeline = described_class.new(config, worker_count: 1)
      pipeline.start

      pipeline.submit([make_entry("hello from pipeline")])
      sleep 0.3

      expect(
        a_request(:post, "http://opentrace.test/api/logs")
          .with { |req|
            body = JSON.parse(req.body)
            body.is_a?(Array) && body.any? { |p| p["message"] == "hello from pipeline" }
          }
      ).to have_been_made

      pipeline.stop(timeout: 2)
    end

    it "increments batches_submitted stat" do
      pipeline = described_class.new(config, worker_count: 1)
      pipeline.start

      pipeline.submit([make_entry])
      pipeline.submit([make_entry])

      expect(pipeline.stats[:batches_submitted]).to eq(2)

      pipeline.stop(timeout: 2)
    end

    it "is a no-op when pipeline is not running" do
      pipeline = described_class.new(config, worker_count: 1)
      # not started
      pipeline.submit([make_entry("should be dropped")])

      expect(pipeline.stats[:batches_submitted]).to eq(0)
    end
  end

  describe "worker processing" do
    it "materializes, serializes, and sends batches" do
      pipeline = described_class.new(config, worker_count: 1)
      pipeline.start

      pipeline.submit([make_entry("materialized message")])
      sleep 0.3

      expect(
        a_request(:post, "http://opentrace.test/api/logs")
          .with(
            headers: {
              "Authorization" => "Bearer test-key",
              "Content-Type" => "application/json",
              "User-Agent" => "opentrace-ruby/#{OpenTrace::VERSION}",
              "X-Api-Version" => OpenTrace::Client::API_VERSION.to_s
            }
          )
      ).to have_been_made

      pipeline.stop(timeout: 2)
    end

    it "uses MessagePack serialization when configured" do
      OpenTrace.configure do |c|
        c.endpoint = "http://opentrace.test"
        c.api_key = "test-key"
        c.service = "test"
        c.serialization_format = :msgpack
        c.compression = false
      end

      stub_request(:post, "http://opentrace.test/api/logs")
        .to_return(status: 201, body: '{"count": 1}')

      pipeline = described_class.new(OpenTrace.config, worker_count: 1)
      pipeline.start

      pipeline.submit([make_entry("msgpack test")])
      sleep 0.3

      expect(
        a_request(:post, "http://opentrace.test/api/logs")
          .with(headers: { "Content-Type" => "application/msgpack" })
      ).to have_been_made

      pipeline.stop(timeout: 2)
    end

    it "uses gzip compression when configured and payload exceeds threshold" do
      OpenTrace.configure do |c|
        c.endpoint = "http://opentrace.test"
        c.api_key = "test-key"
        c.service = "test"
        c.serialization_format = :json
        c.compression = true
        c.compression_threshold = 1  # very low threshold to ensure compression
      end

      stub_request(:post, "http://opentrace.test/api/logs")
        .to_return(status: 201, body: '{"count": 1}')

      pipeline = described_class.new(OpenTrace.config, worker_count: 1)
      pipeline.start

      pipeline.submit([make_entry("compressed payload")])
      sleep 0.3

      expect(
        a_request(:post, "http://opentrace.test/api/logs")
          .with(headers: { "Content-Encoding" => "gzip" })
      ).to have_been_made

      pipeline.stop(timeout: 2)
    end

    it "does not set Content-Encoding when payload is below compression threshold" do
      OpenTrace.configure do |c|
        c.endpoint = "http://opentrace.test"
        c.api_key = "test-key"
        c.service = "test"
        c.serialization_format = :json
        c.compression = true
        c.compression_threshold = 999_999  # very high threshold
      end

      stub_request(:post, "http://opentrace.test/api/logs")
        .to_return(status: 201, body: '{"count": 1}')

      pipeline = described_class.new(OpenTrace.config, worker_count: 1)
      pipeline.start

      pipeline.submit([make_entry("small")])
      sleep 0.3

      expect(
        a_request(:post, "http://opentrace.test/api/logs")
          .with { |req| req.headers["Content-Encoding"].nil? }
      ).to have_been_made

      pipeline.stop(timeout: 2)
    end
  end

  describe "parallel processing" do
    it "multiple workers process batches in parallel" do
      request_count = 0
      request_mutex = Mutex.new

      WebMock.reset!
      stub_request(:post, "http://opentrace.test/api/logs")
        .to_return do |_request|
          request_mutex.synchronize { request_count += 1 }
          { status: 201, body: '{"count": 1}' }
        end

      pipeline = described_class.new(config, worker_count: 4)
      pipeline.start

      10.times { |i| pipeline.submit([make_entry("batch #{i}")]) }
      sleep 1.0

      stats = pipeline.stats
      expect(stats[:batches_submitted]).to eq(10)
      expect(stats[:delivered]).to eq(10)

      pipeline.stop(timeout: 2)
    end
  end

  describe "#stop" do
    it "waits for remaining batches then shuts down workers" do
      pipeline = described_class.new(config, worker_count: 2)
      pipeline.start

      3.times { |i| pipeline.submit([make_entry("drain #{i}")]) }
      pipeline.stop(timeout: 5)

      expect(pipeline.running?).to be false

      # All workers should be dead
      worker_threads = Thread.list.select { |t| t.name&.start_with?("opentrace-pipeline-") }
      expect(worker_threads.select(&:alive?).size).to eq(0)
    end

    it "is idempotent -- calling stop twice is safe" do
      pipeline = described_class.new(config, worker_count: 1)
      pipeline.start
      pipeline.stop(timeout: 2)
      expect { pipeline.stop(timeout: 2) }.not_to raise_error
    end

    it "makes the pipeline a no-op after stop" do
      pipeline = described_class.new(config, worker_count: 1)
      pipeline.start
      pipeline.stop(timeout: 2)

      initial_submitted = pipeline.stats[:batches_submitted]
      pipeline.submit([make_entry("after stop")])

      expect(pipeline.stats[:batches_submitted]).to eq(initial_submitted)
      expect(pipeline.running?).to be false
    end
  end

  describe "#stats" do
    it "tracks delivered, bytes_sent, failed, and errors" do
      pipeline = described_class.new(config, worker_count: 1)
      pipeline.start

      pipeline.submit([make_entry("stats test")])
      sleep 0.3

      stats = pipeline.stats
      expect(stats[:delivered]).to eq(1)
      expect(stats[:bytes_sent]).to be > 0
      expect(stats[:batches_submitted]).to eq(1)

      pipeline.stop(timeout: 2)
    end

    it "tracks failed on non-success responses" do
      WebMock.reset!
      stub_request(:post, "http://opentrace.test/api/logs")
        .to_return(status: 500, body: '{"error": "boom"}')

      pipeline = described_class.new(config, worker_count: 1)
      pipeline.start

      pipeline.submit([make_entry("will fail")])
      sleep 0.3

      stats = pipeline.stats
      expect(stats[:failed]).to eq(1)

      pipeline.stop(timeout: 2)
    end

    it "tracks errors on unexpected exceptions" do
      # Submit a batch with a broken item that will cause Serializer to raise
      # We achieve this by creating a custom config with a bad serialization format
      bad_config = OpenTrace::Config.new.tap do |c|
        c.endpoint = "http://opentrace.test"
        c.api_key = "test-key"
        c.service = "test"
        c.serialization_format = :bogus
      end

      pipeline = described_class.new(bad_config, worker_count: 1)
      pipeline.start

      pipeline.submit([make_entry("error test")])
      sleep 0.3

      stats = pipeline.stats
      expect(stats[:errors]).to be >= 1

      pipeline.stop(timeout: 2)
    end
  end

  describe "connection recovery" do
    it "reconnects on connection failure" do
      call_count = 0
      WebMock.reset!
      stub_request(:post, "http://opentrace.test/api/logs")
        .to_return do |_request|
          call_count += 1
          if call_count == 1
            raise Errno::ECONNRESET, "Connection reset"
          else
            { status: 201, body: '{"count": 1}' }
          end
        end

      pipeline = described_class.new(config, worker_count: 1)
      pipeline.start

      # First batch triggers connection failure, marked as failed
      pipeline.submit([make_entry("first attempt")])
      sleep 0.3

      # Second batch should succeed after reconnecting
      pipeline.submit([make_entry("retry after reconnect")])
      sleep 0.3

      stats = pipeline.stats
      expect(stats[:failed]).to be >= 1
      expect(stats[:delivered]).to be >= 1

      pipeline.stop(timeout: 2)
    end
  end

  describe "thread safety" do
    it "handles concurrent submit from multiple threads" do
      WebMock.reset!
      stub_request(:post, "http://opentrace.test/api/logs")
        .to_return(status: 201, body: '{"count": 1}')

      pipeline = described_class.new(config, worker_count: 4)
      pipeline.start

      threads = 8.times.map do |t|
        Thread.new do
          5.times { |i| pipeline.submit([make_entry("thread-#{t}-msg-#{i}")]) }
        end
      end
      threads.each(&:join)

      sleep 1.0

      stats = pipeline.stats
      expect(stats[:batches_submitted]).to eq(40) # 8 threads * 5 submits
      expect(stats[:delivered]).to eq(40)

      pipeline.stop(timeout: 3)
    end
  end

  describe "skips empty payloads" do
    it "does not send when all entries fail materialization" do
      # Submit entries that won't materialize (nil items)
      pipeline = described_class.new(config, worker_count: 1)
      pipeline.start

      # Push an array of nils -- PayloadBuilder.materialize returns nil for non-Array/non-Hash
      pipeline.submit([nil, nil, nil])
      sleep 0.3

      # No HTTP request should have been made for this batch
      stats = pipeline.stats
      expect(stats[:delivered]).to eq(0)

      pipeline.stop(timeout: 2)
    end
  end
end

RSpec.describe OpenTrace::PipelineStats do
  subject(:stats) { described_class.new }

  describe "#increment" do
    it "increments a counter by 1 by default" do
      stats.increment(:delivered)
      expect(stats.get(:delivered)).to eq(1)
    end

    it "increments a counter by a custom amount" do
      stats.increment(:bytes_sent, 1024)
      expect(stats.get(:bytes_sent)).to eq(1024)
    end
  end

  describe "#get" do
    it "returns 0 for unknown counters" do
      expect(stats.get(:nonexistent)).to eq(0)
    end
  end

  describe "#to_h" do
    it "returns a snapshot of all counters" do
      stats.increment(:delivered, 5)
      stats.increment(:failed, 2)

      h = stats.to_h
      expect(h[:delivered]).to eq(5)
      expect(h[:failed]).to eq(2)
    end

    it "returns a copy, not a reference" do
      stats.increment(:delivered, 1)
      h = stats.to_h
      h[:delivered] = 999
      expect(stats.get(:delivered)).to eq(1)
    end
  end

  describe "#reset!" do
    it "clears all counters" do
      stats.increment(:delivered, 10)
      stats.increment(:errors, 3)
      stats.reset!

      expect(stats.get(:delivered)).to eq(0)
      expect(stats.get(:errors)).to eq(0)
    end
  end

  describe "thread safety" do
    it "handles concurrent increments correctly" do
      threads = 10.times.map do
        Thread.new { 100.times { stats.increment(:delivered) } }
      end
      threads.each(&:join)

      expect(stats.get(:delivered)).to eq(1000)
    end
  end
end
