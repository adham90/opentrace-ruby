# frozen_string_literal: true

require_relative "../spec_helper"
require "opentrace/request_collector"
require "opentrace/request_buffer"
require "opentrace/http_tracker"

RSpec.describe OpenTrace::HttpTracker, "deep capture" do
  before do
    configure_opentrace!
    stub_request(:any, /example\.com/)
      .to_return(status: 200, body: '{"ok":true}')
    stub_request(:post, "https://opentrace.test/api/logs")
      .to_return(status: 201, body: '{"count":1}')
  end

  # Apply the prepend only once
  before(:all) do
    Net::HTTP.prepend(OpenTrace::HttpTracker) unless Net::HTTP.ancestors.include?(OpenTrace::HttpTracker)
  end

  # ── infer_vendor ──

  describe ".infer_vendor" do
    it "returns 'stripe' for api.stripe.com" do
      expect(OpenTrace::HttpTracker.infer_vendor("api.stripe.com")).to eq("stripe")
    end

    it "returns 'sendgrid' for api.sendgrid.com" do
      expect(OpenTrace::HttpTracker.infer_vendor("api.sendgrid.com")).to eq("sendgrid")
    end

    it "returns nil for unknown hosts" do
      expect(OpenTrace::HttpTracker.infer_vendor("example.com")).to be_nil
    end

    it "returns 'aws' for s3.amazonaws.com" do
      expect(OpenTrace::HttpTracker.infer_vendor("s3.amazonaws.com")).to eq("aws")
    end

    it "returns 'google' for www.googleapis.com" do
      expect(OpenTrace::HttpTracker.infer_vendor("www.googleapis.com")).to eq("google")
    end

    it "returns 'twilio' for api.twilio.com" do
      expect(OpenTrace::HttpTracker.infer_vendor("api.twilio.com")).to eq("twilio")
    end

    it "returns 'slack' for hooks.slack.com" do
      expect(OpenTrace::HttpTracker.infer_vendor("hooks.slack.com")).to eq("slack")
    end

    it "returns 'github' for api.github.com" do
      expect(OpenTrace::HttpTracker.infer_vendor("api.github.com")).to eq("github")
    end

    it "returns 'shopify' for mystore.myshopify.com" do
      expect(OpenTrace::HttpTracker.infer_vendor("mystore.myshopify.com")).to eq("shopify")
    end

    it "returns 'plaid' for sandbox.plaid.com" do
      expect(OpenTrace::HttpTracker.infer_vendor("sandbox.plaid.com")).to eq("plaid")
    end

    it "returns nil for nil host" do
      expect(OpenTrace::HttpTracker.infer_vendor(nil)).to be_nil
    end

    it "is case-insensitive" do
      expect(OpenTrace::HttpTracker.infer_vendor("API.STRIPE.COM")).to eq("stripe")
    end
  end

  # ── Buffer recording on success ──

  describe "buffer recording" do
    it "records HTTP call to buffer when buffer is present" do
      buffer = OpenTrace::RequestBuffer.new
      buffer.id = "test-123"
      buffer.started_at = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      Fiber[:opentrace_buffer] = buffer

      uri = URI("https://example.com/api/data")
      Net::HTTP.get(uri)

      expect(buffer.http_captures.size).to eq(1)
      capture = buffer.http_captures.first
      expect(capture[:method]).to eq("GET")
      expect(capture[:host]).to eq("example.com")
      expect(capture[:status]).to eq(200)
      expect(capture[:duration_ms]).to be > 0
      expect(capture[:vendor]).to be_nil # example.com is unknown
    ensure
      Fiber[:opentrace_buffer] = nil
      Fiber[:opentrace_collector] = nil
    end

    it "includes vendor in buffer recording" do
      stub_request(:get, "https://api.stripe.com/v1/charges")
        .to_return(status: 200, body: '{"data":[]}')

      buffer = OpenTrace::RequestBuffer.new
      buffer.id = "test-456"
      buffer.started_at = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      Fiber[:opentrace_buffer] = buffer

      uri = URI("https://api.stripe.com/v1/charges")
      Net::HTTP.get(uri)

      capture = buffer.http_captures.first
      expect(capture[:vendor]).to eq("stripe")
    ensure
      Fiber[:opentrace_buffer] = nil
      Fiber[:opentrace_collector] = nil
    end

    it "records timeline entry to buffer" do
      buffer = OpenTrace::RequestBuffer.new
      buffer.id = "test-789"
      buffer.started_at = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      Fiber[:opentrace_buffer] = buffer

      uri = URI("https://example.com/api/data")
      Net::HTTP.get(uri)

      expect(buffer.timeline.size).to eq(1)
      entry = buffer.timeline.first
      expect(entry[:type]).to eq(:http)
      expect(entry[:name]).to include("GET")
      expect(entry[:name]).to include("example.com")
      expect(entry[:duration_ms]).to be > 0
    ensure
      Fiber[:opentrace_buffer] = nil
      Fiber[:opentrace_collector] = nil
    end

    it "captures response body when under 64KB" do
      small_body = '{"ok":true}'
      stub_request(:get, "https://example.com/api/small")
        .to_return(status: 200, body: small_body)

      buffer = OpenTrace::RequestBuffer.new
      buffer.id = "test-small"
      buffer.started_at = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      Fiber[:opentrace_buffer] = buffer

      uri = URI("https://example.com/api/small")
      Net::HTTP.get(uri)

      capture = buffer.http_captures.first
      expect(capture[:response_body]).to eq(small_body)
      expect(capture[:response_size]).to eq(small_body.bytesize)
    ensure
      Fiber[:opentrace_buffer] = nil
      Fiber[:opentrace_collector] = nil
    end

    it "captures request body when under 64KB" do
      stub_request(:post, "https://example.com/api/create")
        .to_return(status: 201, body: '{"id":1}')

      buffer = OpenTrace::RequestBuffer.new
      buffer.id = "test-reqbody"
      buffer.started_at = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      Fiber[:opentrace_buffer] = buffer

      uri = URI("https://example.com/api/create")
      req_body = '{"name":"test"}'
      http = Net::HTTP.new(uri.host, uri.port)
      http.use_ssl = true
      request = Net::HTTP::Post.new(uri.path)
      request.body = req_body
      request.content_type = "application/json"
      http.request(request)

      capture = buffer.http_captures.first
      expect(capture[:request_body]).to eq(req_body)
    ensure
      Fiber[:opentrace_buffer] = nil
      Fiber[:opentrace_collector] = nil
    end

    it "never raises to the host app when bookkeeping itself explodes" do
      # The tracker's core contract: a bug in OpenTrace's own bookkeeping code
      # must never crash the host app's HTTP call. Prove it by making the
      # RequestBuffer#record_http method raise — the outer Net::HTTP call
      # must still return the real response unchanged.
      buffer = OpenTrace::RequestBuffer.new
      buffer.id = "test-boom"
      buffer.started_at = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      def buffer.record_http(**); raise "boom from bookkeeping"; end
      Fiber[:opentrace_buffer] = buffer

      uri = URI("https://example.com/api/data")
      response = nil
      expect { response = Net::HTTP.get_response(uri) }.not_to raise_error
      expect(response.code).to eq("200")
    ensure
      Fiber[:opentrace_buffer] = nil
      Fiber[:opentrace_collector] = nil
    end

    it "handles streaming responses where body is a Net::ReadAdapter" do
      # When Net::HTTP#request is called with a block (streaming), response.body
      # becomes a Net::ReadAdapter instead of a String — it has no #bytesize.
      # Regression test for a crash on RubyLLM streaming / any block-form request.
      stub_request(:get, "https://example.com/api/stream")
        .to_return(status: 200, body: "chunk-data")

      buffer = OpenTrace::RequestBuffer.new
      buffer.id = "test-stream"
      buffer.started_at = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      Fiber[:opentrace_buffer] = buffer

      uri = URI("https://example.com/api/stream")
      http = Net::HTTP.new(uri.host, uri.port)
      http.use_ssl = true
      request = Net::HTTP::Get.new(uri.path)

      expect {
        http.request(request) do |response|
          # Force body into the Net::ReadAdapter state (what streaming does)
          response.instance_variable_set(:@body, Net::ReadAdapter.new(->(_) {}))
        end
      }.not_to raise_error

      capture = buffer.http_captures.first
      expect(capture[:response_size]).to be_nil
      expect(capture[:response_body]).to be_nil
    ensure
      Fiber[:opentrace_buffer] = nil
      Fiber[:opentrace_collector] = nil
    end

    it "does not capture response body when over 64KB" do
      large_body = "x" * 70_000  # > 64KB
      stub_request(:get, "https://example.com/api/large")
        .to_return(status: 200, body: large_body)

      buffer = OpenTrace::RequestBuffer.new
      buffer.id = "test-large"
      buffer.started_at = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      Fiber[:opentrace_buffer] = buffer

      uri = URI("https://example.com/api/large")
      Net::HTTP.get(uri)

      capture = buffer.http_captures.first
      expect(capture[:response_body]).to be_nil
      expect(capture[:response_size]).to eq(large_body.bytesize)
    ensure
      Fiber[:opentrace_buffer] = nil
      Fiber[:opentrace_collector] = nil
    end

    it "does not record to buffer when buffer is absent" do
      Fiber[:opentrace_buffer] = nil

      uri = URI("https://example.com/api/data")
      # Should not raise
      expect { Net::HTTP.get(uri) }.not_to raise_error
    end

    it "does not record to buffer when recursion guard is set" do
      buffer = OpenTrace::RequestBuffer.new
      buffer.id = "test-guard"
      buffer.started_at = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      Fiber[:opentrace_buffer] = buffer
      Fiber[:opentrace_http_tracking_disabled] = true

      uri = URI("https://example.com/api/data")
      Net::HTTP.get(uri)

      expect(buffer.http_captures).to be_empty
    ensure
      Fiber[:opentrace_buffer] = nil
      Fiber[:opentrace_http_tracking_disabled] = nil
    end

    it "does not record to buffer when OpenTrace is disabled" do
      OpenTrace.disable!
      buffer = OpenTrace::RequestBuffer.new
      buffer.id = "test-disabled"
      buffer.started_at = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      Fiber[:opentrace_buffer] = buffer

      uri = URI("https://example.com/api/data")
      Net::HTTP.get(uri)

      expect(buffer.http_captures).to be_empty
    ensure
      Fiber[:opentrace_buffer] = nil
    end
  end

  # ── Error recording to buffer ──

  describe "error recording to buffer" do
    it "records error to buffer with error_class" do
      stub_request(:get, "https://timeout.example.com/slow")
        .to_timeout

      buffer = OpenTrace::RequestBuffer.new
      buffer.id = "test-error"
      buffer.started_at = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      Fiber[:opentrace_buffer] = buffer

      expect {
        uri = URI("https://timeout.example.com/slow")
        Net::HTTP.get(uri)
      }.to raise_error(Net::OpenTimeout)

      expect(buffer.http_captures.size).to eq(1)
      capture = buffer.http_captures.first
      expect(capture[:status]).to eq(0)
      expect(capture[:error_class]).to eq("Net::OpenTimeout")
      expect(capture[:host]).to eq("timeout.example.com")
      expect(capture[:response_body]).to be_nil
      expect(capture[:response_size]).to be_nil
    ensure
      Fiber[:opentrace_buffer] = nil
      Fiber[:opentrace_collector] = nil
    end

    it "includes vendor in error recording" do
      stub_request(:get, "https://api.stripe.com/v1/charges")
        .to_timeout

      buffer = OpenTrace::RequestBuffer.new
      buffer.id = "test-error-vendor"
      buffer.started_at = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      Fiber[:opentrace_buffer] = buffer

      expect {
        uri = URI("https://api.stripe.com/v1/charges")
        Net::HTTP.get(uri)
      }.to raise_error(Net::OpenTimeout)

      capture = buffer.http_captures.first
      expect(capture[:vendor]).to eq("stripe")
      expect(capture[:error_class]).to eq("Net::OpenTimeout")
    ensure
      Fiber[:opentrace_buffer] = nil
      Fiber[:opentrace_collector] = nil
    end
  end
end
