# frozen_string_literal: true

require_relative "../spec_helper"
require_relative "../dummy/app"

RSpec.describe "Performance integration" do
  before do
    stub_request(:post, "https://opentrace.test/api/logs")
      .to_return(status: 201, body: '{"count":1}')
  end

  describe "request latency impact" do
    it "adds less than 5ms overhead per request with full features enabled" do
      configure_opentrace!(
        request_summary: true,
        context: -> { { user_id: 42, platform: "web" } }
      )

      inner_app = Dummy::App.new
      middleware = OpenTrace::Middleware.new(inner_app)

      # Baseline: app without middleware
      baseline_times = []
      50.times do
        start = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        inner_app.call({})
        baseline_times << (Process.clock_gettime(Process::CLOCK_MONOTONIC) - start) * 1000
      end

      # With OpenTrace middleware
      with_ot_times = []
      50.times do |i|
        start = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        middleware.call("action_dispatch.request_id" => "req-#{i}")
        with_ot_times << (Process.clock_gettime(Process::CLOCK_MONOTONIC) - start) * 1000
      end

      baseline_avg = baseline_times.sum / baseline_times.size
      with_ot_avg = with_ot_times.sum / with_ot_times.size
      overhead = with_ot_avg - baseline_avg

      expect(overhead).to be < 5.0,
        "OpenTrace added #{overhead.round(2)}ms overhead per request " \
        "(baseline: #{baseline_avg.round(2)}ms, with OT: #{with_ot_avg.round(2)}ms)"
    end

    it "context proc only runs once per request even with many log calls" do
      call_count = 0
      expensive_work_ms = 0

      configure_opentrace!(
        request_summary: true,
        context: -> {
          call_count += 1
          # Simulate expensive context resolution (Browser.new, DB query, etc.)
          start = Process.clock_gettime(Process::CLOCK_MONOTONIC)
          100.times { "simulate_work" * 100 }  # ~0.1ms of work
          expensive_work_ms += (Process.clock_gettime(Process::CLOCK_MONOTONIC) - start) * 1000
          { user_id: 42, email: "test@test.com", platform: "iOS" }
        }
      )

      app = Dummy::ExpensiveContextApp.new
      middleware = OpenTrace::Middleware.new(app)

      middleware.call("action_dispatch.request_id" => "ctx-test")

      # Context proc should only be called ONCE despite 10 log calls
      expect(call_count).to eq(1),
        "Context proc called #{call_count} times (expected 1). " \
        "Total expensive work: #{expensive_work_ms.round(2)}ms"
    end

    it "handles high-throughput without degradation" do
      configure_opentrace!(
        request_summary: true,
        context: -> { { user_id: 1 } }
      )

      inner_app = ->(env) { [200, {}, ["OK"]] }
      middleware = OpenTrace::Middleware.new(inner_app)

      # Process 200 requests and check that latency stays consistent
      first_50 = []
      last_50 = []

      200.times do |i|
        start = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        middleware.call("action_dispatch.request_id" => "ht-#{i}")
        OpenTrace.log("INFO", "request #{i}")
        elapsed = (Process.clock_gettime(Process::CLOCK_MONOTONIC) - start) * 1000

        first_50 << elapsed if i < 50
        last_50 << elapsed if i >= 150
      end

      first_avg = first_50.sum / first_50.size
      last_avg = last_50.sum / last_50.size

      # Last 50 should not be significantly slower than first 50
      # (no degradation from queue buildup, mutex contention, etc.)
      # Using 5x threshold because at sub-millisecond scale, noise dominates
      ratio = last_avg / [first_avg, 0.001].max
      expect(ratio).to be < 5.0,
        "Latency degradation detected: first 50 avg=#{first_avg.round(3)}ms, " \
        "last 50 avg=#{last_avg.round(3)}ms (ratio: #{ratio.round(1)}x)"
    end
  end

  describe "LogForwarder level matching" do
    it "does not process DEBUG messages when min_level is :info" do
      configure_opentrace!(min_level: :info)
      forwarder = OpenTrace::LogForwarder.new

      debug_evaluated = false
      forwarder.add(::Logger::DEBUG) { debug_evaluated = true; "expensive debug" }

      expect(debug_evaluated).to be false
      expect(forwarder.level).to eq(::Logger::INFO)
    end

    it "processes INFO messages when min_level is :info" do
      configure_opentrace!(min_level: :info)
      forwarder = OpenTrace::LogForwarder.new

      info_evaluated = false
      forwarder.add(::Logger::INFO) { info_evaluated = true; "info message" }

      expect(info_evaluated).to be true
    end
  end

  describe "thread safety under concurrent load" do
    it "handles concurrent requests without errors" do
      configure_opentrace!(
        request_summary: true,
        context: -> { { user_id: rand(1000) } }
      )

      inner_app = ->(env) {
        3.times { OpenTrace.log("INFO", "concurrent #{Thread.current.object_id}") }
        [200, {}, ["OK"]]
      }
      middleware = OpenTrace::Middleware.new(inner_app)

      errors = []
      threads = 4.times.map do |t|
        Thread.new do
          10.times do |i|
            middleware.call("action_dispatch.request_id" => "thread-#{t}-req-#{i}")
          end
        rescue => e
          errors << e
        end
      end

      threads.each(&:join)

      expect(errors).to be_empty, "Errors during concurrent requests: #{errors.map(&:message)}"
    end
  end
end
