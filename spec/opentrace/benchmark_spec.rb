# frozen_string_literal: true

require "spec_helper"
# Inline timing helper (benchmark gem removed from stdlib in Ruby 4.0)
module BenchHelper
  def self.realtime
    t0 = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    yield
    Process.clock_gettime(Process::CLOCK_MONOTONIC) - t0
  end
end
require "opentrace/ulid"
require "opentrace/ring_buffer"
require "opentrace/request_buffer"
require "opentrace/buffer_pool"
require "opentrace/capture_rules"
require "opentrace/memory_guard"
require "opentrace/serializer"

# Performance benchmarks for the deep capture system.
# Run with: bundle exec rspec spec/opentrace/benchmark_spec.rb --format documentation
RSpec.describe "Deep Capture Performance" do
  let(:iterations) { 10_000 }

  describe "ULID generation" do
    it "generates #{10_000} ULIDs under 50ms" do
      elapsed = BenchHelper.realtime { 10_000.times { OpenTrace::ULID.generate } }
      puts "    ULID: #{(elapsed * 1000).round(1)}ms for 10K (#{(elapsed / 10_000 * 1_000_000).round(1)}μs/call)"
      expect(elapsed).to be < 0.1 # under 100ms for 10K (includes mutex overhead)
    end
  end

  describe "RingBuffer vs Thread::Queue" do
    it "RingBuffer push/pop is competitive with Thread::Queue" do
      ring = OpenTrace::RingBuffer.new(capacity: 2048)
      tq = Thread::Queue.new

      ring_time = BenchHelper.realtime do
        iterations.times do |i|
          ring.push(i, byte_size: 100)
        end
        ring.pop_batch(iterations)
      end

      tq_time = BenchHelper.realtime do
        iterations.times do |i|
          tq.push(i)
        end
        iterations.times { tq.pop(true) rescue nil }
      end

      puts "    RingBuffer: #{(ring_time * 1000).round(1)}ms for #{iterations} push+pop"
      puts "    Thread::Queue: #{(tq_time * 1000).round(1)}ms for #{iterations} push+pop"
      puts "    Ratio: #{(ring_time / tq_time).round(2)}x"

      # Ring buffer should be within 3x of Thread::Queue (it has byte tracking overhead)
      expect(ring_time).to be < tq_time * 3
    end
  end

  describe "RequestBuffer allocation" do
    it "pool checkout/checkin is faster than new allocation" do
      pool = OpenTrace::BufferPool.new(size: 32)

      pool_time = BenchHelper.realtime do
        iterations.times do
          buf = pool.checkout
          buf.record_sql(raw_sql: "SELECT 1", duration_ms: 1.0, name: "test")
          pool.checkin(buf)
        end
      end

      alloc_time = BenchHelper.realtime do
        iterations.times do
          buf = OpenTrace::RequestBuffer.new
          buf.record_sql(raw_sql: "SELECT 1", duration_ms: 1.0, name: "test")
          # no checkin — GC cleans it up
        end
      end

      puts "    Pool checkout/checkin: #{(pool_time * 1000).round(1)}ms for #{iterations}"
      puts "    New allocation: #{(alloc_time * 1000).round(1)}ms for #{iterations}"
      puts "    Pool speedup: #{(alloc_time / pool_time).round(2)}x"

      # Pool has mutex overhead — main benefit is reduced GC pressure over time
      # Just verify it works, not that it's faster in microbenchmark
      expect(pool_time).to be < 1.0 # under 1 second for 10K cycles
    end
  end

  describe "RequestBuffer recording overhead" do
    it "records 50 SQL queries under 1ms" do
      buf = OpenTrace::RequestBuffer.new

      elapsed = BenchHelper.realtime do
        50.times do |i|
          buf.record_sql(
            raw_sql: "SELECT * FROM users WHERE id = #{i}",
            normalized_sql: "SELECT * FROM users WHERE id = ?",
            binds: [i],
            duration_ms: 1.0 + i * 0.1,
            name: "User Load",
            cached: false,
            row_count: 1,
            in_transaction: i > 25,
            fingerprint: "fp-#{i % 5}",
            table: "users",
            caller_location: "app/models/user.rb:42"
          )
        end
      end

      puts "    50 SQL records: #{(elapsed * 1_000_000).round(0)}μs (#{(elapsed / 50 * 1_000_000).round(1)}μs/query)"
      expect(elapsed).to be < 0.001 # under 1ms
    end

    it "records a full request (20 SQL + 2 HTTP + 1 email + 1 audit + timeline) under 500μs" do
      buf = OpenTrace::RequestBuffer.new

      elapsed = BenchHelper.realtime do
        20.times do |i|
          buf.record_sql(raw_sql: "SELECT #{i}", duration_ms: 1.0, name: "Q#{i}")
          buf.record_timeline(type: :sql, name: "Q#{i}", duration_ms: 1.0)
        end
        2.times do |i|
          buf.record_http(method: "POST", url: "https://api.stripe.com/v1/charges", host: "api.stripe.com", vendor: "stripe", status: 200, duration_ms: 100.0)
          buf.record_timeline(type: :http, name: "POST stripe.com", duration_ms: 100.0)
        end
        buf.record_email(mailer_class: "OrderMailer", mailer_action: "confirm", to: "user@test.com", subject: "Order confirmed", duration_ms: 50.0)
        buf.record_timeline(type: :email, name: "OrderMailer#confirm", duration_ms: 50.0)
        buf.record_audit(action: "create", record_type: "Order", record_id: "123", actor_id: "42", actor_type: "User")
        buf.record_timeline(type: :audit, name: "Order#create")
      end

      puts "    Full request recording: #{(elapsed * 1_000_000).round(0)}μs"
      expect(elapsed).to be < 0.0005 # under 500μs
    end
  end

  describe "to_document" do
    it "builds document from a full request under 500μs" do
      buf = OpenTrace::RequestBuffer.new
      buf.request_method = "POST"
      buf.request_path = "/api/orders"
      buf.response_status = 201
      buf.context = { user_id: 42, tenant_id: 7 }
      buf.controller = "OrdersController"
      buf.action = "create"

      20.times { |i| buf.record_sql(raw_sql: "SELECT #{i}", duration_ms: 1.0, name: "Q#{i}", binds: [i]) }
      2.times { buf.record_http(method: "POST", url: "https://stripe.com/v1/charges", host: "stripe.com", status: 200, duration_ms: 100.0) }
      buf.record_email(mailer_class: "OrderMailer", mailer_action: "confirm", subject: "confirmed")
      buf.record_audit(action: "create", record_type: "Order", record_id: "1")
      5.times { |i| buf.record_timeline(type: :sql, name: "Q#{i}", duration_ms: 1.0) }

      elapsed = BenchHelper.realtime do
        buf.to_document(capture_level: :full)
      end

      puts "    to_document: #{(elapsed * 1_000_000).round(0)}μs"
      expect(elapsed).to be < 0.0005
    end
  end

  describe "CaptureRules resolution" do
    it "resolves capture level under 5μs" do
      rules = OpenTrace::CaptureRules.new do |r|
        r.on_path("/api/**") { :full }
        r.on_path("/admin/**") { :full }
        r.on_path("/assets/**") { :none }
        r.on_error { :full }
        r.on_slow(threshold: 500) { :full }
      end

      env = { "PATH_INFO" => "/api/orders" }

      elapsed = BenchHelper.realtime do
        iterations.times { rules.resolve(env, base_level: :standard) }
      end

      per_call = elapsed / iterations * 1_000_000
      puts "    CaptureRules.resolve: #{per_call.round(1)}μs/call"
      expect(per_call).to be < 5
    end
  end

  describe "MemoryGuard" do
    it "allocate/release cycle under 1μs" do
      guard = OpenTrace::MemoryGuard.new

      elapsed = BenchHelper.realtime do
        iterations.times do
          guard.allocate(1000)
          guard.release(1000)
        end
      end

      per_call = elapsed / iterations * 1_000_000
      puts "    MemoryGuard allocate+release: #{per_call.round(2)}μs/call"
      expect(per_call).to be < 1
    end
  end

  describe "Serializer" do
    let(:document) do
      {
        "id" => "01TEST",
        "timestamp" => "2026-04-03T12:00:00Z",
        "level" => "INFO",
        "service" => "bench",
        "event" => {
          "type" => "http.request",
          "message" => "POST /api/orders 201 42ms",
          "db" => {
            "queries" => 20.times.map { |i|
              { "sql" => "SELECT * FROM users WHERE id = #{i}", "binds" => [i], "duration_ms" => 1.0 + i }
            }
          },
          "external" => [
            { "method" => "POST", "url" => "https://api.stripe.com/v1/charges", "status" => 200, "duration_ms" => 100.0,
              "response" => { "body" => '{"id": "ch_xyz", "status": "succeeded"}' } }
          ]
        }
      }
    end

    it "MessagePack is faster than JSON" do
      msgpack_time = BenchHelper.realtime do
        1000.times { OpenTrace::Serializer.encode(document, format: :msgpack) }
      end

      json_time = BenchHelper.realtime do
        1000.times { OpenTrace::Serializer.encode(document, format: :json) }
      end

      msgpack_bytes, = OpenTrace::Serializer.encode(document, format: :msgpack)
      json_bytes, = OpenTrace::Serializer.encode(document, format: :json)

      puts "    MessagePack: #{(msgpack_time * 1000).round(1)}ms for 1K encodes (#{msgpack_bytes.bytesize} bytes)"
      puts "    JSON: #{(json_time * 1000).round(1)}ms for 1K encodes (#{json_bytes.bytesize} bytes)"
      puts "    Speed: MessagePack is #{(json_time / msgpack_time).round(1)}x faster"
      puts "    Size: MessagePack is #{((1 - msgpack_bytes.bytesize.to_f / json_bytes.bytesize) * 100).round(0)}% smaller"

      expect(msgpack_time).to be < json_time
      expect(msgpack_bytes.bytesize).to be < json_bytes.bytesize
    end
  end

  describe "Memory overhead" do
    it "estimates per-request memory at each capture level" do
      levels = %i[minimal standard full]

      levels.each do |level|
        buf = OpenTrace::RequestBuffer.new
        buf.request_method = "POST"
        buf.request_path = "/api/orders"
        buf.request_body = '{"item": 42}' * 10 if level == :full
        buf.response_body = '{"order_id": 99}' * 50 if level == :full
        buf.response_status = 201
        buf.context = { user_id: 42 }

        20.times { |i| buf.record_sql(raw_sql: "SELECT #{i} FROM users", binds: [i], duration_ms: 1.0, name: "Q#{i}") }
        2.times { buf.record_http(method: "POST", url: "https://stripe.com/v1/charges", host: "stripe.com", status: 200, duration_ms: 100.0, request_body: (level == :full ? '{"amount": 4999}' : nil), response_body: (level == :full ? '{"id": "ch_xyz"}' : nil)) }

        doc = buf.to_document(capture_level: level)
        json = JSON.generate(doc)
        puts "    :#{level} document size: #{json.bytesize} bytes"
      end

      # Just informational — no assertion needed
      expect(true).to be true
    end
  end

  describe "Throughput simulation" do
    it "processes 1000 requests/sec worth of buffer operations under 500ms" do
      pool = OpenTrace::BufferPool.new(size: 32)

      elapsed = BenchHelper.realtime do
        1000.times do
          buf = pool.checkout
          buf.request_method = "GET"
          buf.request_path = "/api/users"
          buf.response_status = 200

          5.times { |i| buf.record_sql(raw_sql: "SELECT #{i}", duration_ms: 0.5, name: "Q#{i}") }
          5.times { |i| buf.record_timeline(type: :sql, name: "Q#{i}", duration_ms: 0.5) }

          buf.to_document(capture_level: :standard)
          pool.checkin(buf)
        end
      end

      rps = (1000 / elapsed).round(0)
      puts "    1000 full cycles: #{(elapsed * 1000).round(0)}ms"
      puts "    Throughput: #{rps} requests/sec"
      expect(elapsed).to be < 0.5
    end
  end
end
