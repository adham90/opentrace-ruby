# frozen_string_literal: true

require "webmock/rspec"
require "opentrace"

WebMock.disable_net_connect!

RSpec.configure do |config|
  config.before(:each) do
    # Stub all requests to the test endpoint as a safety net
    stub_request(:any, /opentrace\.test/)
      .to_return(status: 200, body: '{"count":0}')

    # Clean up Fiber-local state from previous tests
    Fiber[:opentrace_request_id] = nil
    Fiber[:opentrace_sql_count] = nil
    Fiber[:opentrace_sql_total_ms] = nil
    Fiber[:opentrace_collector] = nil
    Fiber[:opentrace_cached_context] = nil
    Fiber[:opentrace_logging] = nil
    Fiber[:opentrace_http_tracking_disabled] = nil
    Fiber[:opentrace_trace_id] = nil
    Fiber[:opentrace_span_id] = nil
    Fiber[:opentrace_parent_span_id] = nil
    Fiber[:opentrace_buffer] = nil
    Fiber[:opentrace_buffer_allocation_bytes] = nil

    OpenTrace.reset!
    OpenTrace::InstrumentationContext.reset!
  end

  config.after(:each) do
    OpenTrace.shutdown(timeout: 2)
  end

  config.order = :random
end

def configure_opentrace!(overrides = {})
  OpenTrace.configure do |c|
    c.endpoint       = overrides.fetch(:endpoint, "https://opentrace.test")
    c.api_key        = overrides.fetch(:api_key, "test-key-123")
    c.service        = overrides.fetch(:service, "test-service")
    c.environment    = overrides.fetch(:environment, "test")
    c.timeout        = overrides.fetch(:timeout, 1.0)
    c.enabled        = overrides.fetch(:enabled, true)
    c.flush_interval = overrides.fetch(:flush_interval, 0.2) # fast flush for tests
    c.batch_size     = overrides.fetch(:batch_size, 50)
    c.compression    = overrides.fetch(:compression, false) # disable compression in tests by default
    c.min_level      = overrides.fetch(:min_level, :debug)
    c.context        = overrides[:context] if overrides.key?(:context)
    # Only override these if explicitly provided — preserve Config defaults otherwise
    c.sql_logging          = overrides[:sql_logging]          if overrides.key?(:sql_logging)
    c.request_summary      = overrides[:request_summary]      if overrides.key?(:request_summary)
    c.memory_tracking      = overrides[:memory_tracking]      if overrides.key?(:memory_tracking)
    c.http_tracking        = overrides[:http_tracking]        if overrides.key?(:http_tracking)
    c.log_forwarding       = overrides[:log_forwarding]       if overrides.key?(:log_forwarding)
    c.view_tracking        = overrides[:view_tracking]        if overrides.key?(:view_tracking)
    c.cache_tracking       = overrides[:cache_tracking]       if overrides.key?(:cache_tracking)
    c.deprecation_tracking = overrides[:deprecation_tracking] if overrides.key?(:deprecation_tracking)
    c.detailed_request_log = overrides[:detailed_request_log] if overrides.key?(:detailed_request_log)
    c.timeline             = overrides[:timeline]             if overrides.key?(:timeline)
    c.timeline_max_events  = overrides[:timeline_max_events]  if overrides.key?(:timeline_max_events)
    c.sample_rate          = overrides[:sample_rate]          if overrides.key?(:sample_rate)
    c.sampler              = overrides[:sampler]              if overrides.key?(:sampler)
    c.before_send          = overrides[:before_send]          if overrides.key?(:before_send)
    c.ignore_paths         = overrides[:ignore_paths]         if overrides.key?(:ignore_paths)
    c.capture_depth        = overrides[:capture_depth]        if overrides.key?(:capture_depth)
    c.email_capture        = overrides[:email_capture]        if overrides.key?(:email_capture)
    c.sql_capture          = overrides[:sql_capture]          if overrides.key?(:sql_capture)
    c.http_capture         = overrides[:http_capture]         if overrides.key?(:http_capture)
    c.audit_capture        = overrides[:audit_capture]        if overrides.key?(:audit_capture)
    c.request_capture      = overrides[:request_capture]      if overrides.key?(:request_capture)
    c.max_total_buffer_bytes = overrides[:max_total_buffer_bytes] if overrides.key?(:max_total_buffer_bytes)
  end
end

# Helper to decompress gzip body if needed
def decompress_body(raw_body)
  gz = Zlib::GzipReader.new(StringIO.new(raw_body))
  gz.read
rescue Zlib::GzipFile::Error
  raw_body
ensure
  gz&.close
end

# Helper to parse batch body from request (payloads are always sent as arrays)
# Handles compressed/uncompressed, JSON/MessagePack bodies.
# Normalizes the new event-based document format so tests that check
# body["level"], body["message"], body["metadata"] continue to work.
def parse_log_entries(req)
  raw = decompress_body(req.body)
  body = begin
    JSON.parse(raw)
  rescue JSON::ParserError
    require "msgpack"
    MessagePack.unpack(raw)
  end
  entries = body.is_a?(Array) ? body : [body]
  entries.map { |e| normalize_log_entry(e) }
end

def parse_log_body(req)
  parse_log_entries(req).first
end

def normalize_log_entry(entry)
  return entry unless entry.is_a?(Hash)

  # Legacy event-based format (pre-flat)
  if entry.key?("event") && !entry.key?("message")
    event = entry["event"]
    if event.is_a?(Hash)
      entry["message"]  = event["message"]  if event.key?("message")
      entry["metadata"] = event["metadata"] if event.key?("metadata")
      entry["event_type"] = event["type"] if event.key?("type")
    end
  end

  # Flat SDK format: level is lowercase, normalize to uppercase for test compat
  if entry.key?("level") && entry["level"] == entry["level"].downcase
    entry["level"] = entry["level"].upcase
  end

  # Flat SDK: metadata + context both live in body.context (static + config + user merged).
  # Alias both names so tests written against either semantic keep working.
  if entry.key?("body") && entry["body"].is_a?(Hash) && entry["body"].key?("context")
    entry["metadata"] ||= entry["body"]["context"]
    entry["context"]  ||= entry["body"]["context"]
  end

  # Flat SDK: environment is "env", timestamp is "ts"
  entry["environment"] = entry["env"] if entry.key?("env") && !entry.key?("environment")
  entry["timestamp"]   = entry["ts"]  if entry.key?("ts")  && !entry.key?("timestamp")

  if entry.key?("context")
    ctx = entry["context"]
    if ctx.is_a?(Hash)
      # Promote well-known context fields to top level, but don't clobber an
      # existing top-level value — the flat schema emits the real trace_id at
      # the top, while body.context can contain a user-metadata trace_id.
      %w[trace_id span_id parent_span_id request_id hostname pid].each do |k|
        entry[k] ||= ctx[k] if ctx.key?(k)
      end
    end
  end

  entry
end
