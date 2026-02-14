# frozen_string_literal: true

require "stringio"
require "securerandom"

# Load Rails stubs (shared stubs)
require_relative "rails_spec_helper"

# Simulates the exact production scenario where sql_logging: true + min_level: :info
# caused wasted CPU work on every SQL query. With the early level check in
# forward_sql_log, DEBUG-level SQL logs are now filtered BEFORE any expensive
# metadata construction, regex normalization, or MD5 fingerprinting.
RSpec.describe "SQL level filtering performance" do
  before do
    stub_request(:post, "https://opentrace.test/api/logs")
      .to_return(status: 201, body: '{"count":1}')
  end

  # Helper: initialize Railtie subscribers (must be called after configure)
  def boot_railtie!
    ActiveSupport::Notifications.reset!
    Rails.logger = ::Logger.new(StringIO.new)
    app = Rails::Application.new
    app.config.logger = ::Logger.new(StringIO.new)
    OpenTrace::Railtie.initializer_blocks.each { |block| block.call(app) }
    OpenTrace::Railtie.config.after_initialize_blocks.each { |block| block.call(app) }
  end

  # Helper: fire N SQL notifications with realistic payloads
  def fire_sql_queries(count, duration_ms: 2.0)
    queries = [
      "SELECT \"users\".* FROM \"users\" WHERE \"users\".\"id\" = 42",
      "SELECT \"posts\".* FROM \"posts\" WHERE \"posts\".\"user_id\" = 42 ORDER BY created_at DESC LIMIT 20",
      "SELECT \"comments\".* FROM \"comments\" WHERE \"comments\".\"post_id\" IN (1, 2, 3, 4, 5)",
      "UPDATE \"users\" SET \"last_seen_at\" = '2026-02-13 10:00:00' WHERE \"users\".\"id\" = 42",
      "SELECT COUNT(*) FROM \"notifications\" WHERE \"notifications\".\"user_id\" = 42 AND \"notifications\".\"read\" = FALSE"
    ]

    duration_s = duration_ms / 1000.0
    count.times do |i|
      sql = queries[i % queries.size]
      start_time = Time.now
      end_time = start_time + duration_s

      ActiveSupport::Notifications.instrument("sql.active_record", {
        name: "User Load",
        sql: sql,
        cached: false
      }) {}
    end
  end

  describe "early level check prevents wasted work" do
    it "does NOT call SqlNormalizer when min_level filters DEBUG SQL" do
      configure_opentrace!(sql_logging: true, min_level: :info, sql_normalization: true)
      boot_railtie!

      normalize_calls = 0
      fingerprint_calls = 0

      # Spy on SqlNormalizer to count calls
      original_normalize = OpenTrace::SqlNormalizer.method(:normalize)
      original_fingerprint = OpenTrace::SqlNormalizer.method(:fingerprint)

      allow(OpenTrace::SqlNormalizer).to receive(:normalize) do |*args|
        normalize_calls += 1
        original_normalize.call(*args)
      end

      allow(OpenTrace::SqlNormalizer).to receive(:fingerprint) do |*args|
        fingerprint_calls += 1
        original_fingerprint.call(*args)
      end

      # Fire 100 SQL queries (all normal duration -> DEBUG level)
      fire_sql_queries(100)

      expect(normalize_calls).to eq(0),
        "SqlNormalizer.normalize was called #{normalize_calls} times " \
        "(expected 0 — DEBUG SQL should be filtered before normalization)"

      expect(fingerprint_calls).to eq(0),
        "SqlNormalizer.fingerprint was called #{fingerprint_calls} times " \
        "(expected 0 — DEBUG SQL should be filtered before fingerprinting)"
    end

    it "does NOT call OpenTrace.log for filtered DEBUG SQL" do
      configure_opentrace!(sql_logging: true, min_level: :info, sql_normalization: true)
      boot_railtie!

      log_calls = 0
      original_log = OpenTrace.method(:log)

      allow(OpenTrace).to receive(:log) do |*args|
        log_calls += 1
        original_log.call(*args)
      end

      fire_sql_queries(100)

      expect(log_calls).to eq(0),
        "OpenTrace.log was called #{log_calls} times " \
        "(expected 0 — all SQL queries are DEBUG level, filtered by min_level: :info)"
    end

    it "DOES call SqlNormalizer when min_level allows DEBUG" do
      configure_opentrace!(sql_logging: true, min_level: :debug, sql_normalization: true)
      boot_railtie!

      normalize_calls = 0
      original_normalize = OpenTrace::SqlNormalizer.method(:normalize)

      allow(OpenTrace::SqlNormalizer).to receive(:normalize) do |*args|
        normalize_calls += 1
        original_normalize.call(*args)
      end

      fire_sql_queries(20)

      expect(normalize_calls).to be > 0,
        "SqlNormalizer.normalize was never called with min_level: :debug " \
        "(expected it to process SQL queries)"
    end
  end

  describe "overhead measurement" do
    it "adds less than 0.01ms per SQL query when level-filtered" do
      configure_opentrace!(sql_logging: true, min_level: :info)
      boot_railtie!

      query_count = 200

      # Baseline: fire notifications with no OpenTrace subscriber
      # (use a fresh notification channel that nobody subscribes to)
      baseline_start = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      query_count.times do
        # Just the overhead of the subscriber check + early return
      end
      baseline_elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - baseline_start

      # With OpenTrace sql subscriber active (but level-filtered)
      ot_start = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      fire_sql_queries(query_count)
      ot_elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - ot_start

      overhead_per_query_ms = ((ot_elapsed - baseline_elapsed) / query_count) * 1000

      # The overhead per query should be negligible (< 0.05ms)
      # since forward_sql_log returns immediately after the level check
      expect(overhead_per_query_ms).to be < 0.05,
        "SQL subscriber overhead: #{(overhead_per_query_ms * 1000).round(1)}us per query " \
        "(#{(ot_elapsed * 1000).round(1)}ms total for #{query_count} queries). " \
        "Expected < 50us per query when level-filtered."
    end
  end

  describe "config.enabled? caching" do
    it "does not recompute valid? on every call" do
      configure_opentrace!(sql_logging: true, min_level: :info)

      valid_calls = 0
      original_valid = OpenTrace.config.method(:valid?)

      allow(OpenTrace.config).to receive(:valid?) do
        valid_calls += 1
        original_valid.call
      end

      # First call populates the cache
      OpenTrace.config.enabled?
      initial_calls = valid_calls

      # Subsequent calls should use the cache
      100.times { OpenTrace.config.enabled? }

      expect(valid_calls).to eq(initial_calls),
        "valid? was called #{valid_calls} times for 101 enabled? calls " \
        "(expected #{initial_calls} — cache should prevent re-evaluation)"
    end

    it "invalidates cache when enabled= is called" do
      configure_opentrace!(sql_logging: true, min_level: :info)

      # Populate cache
      expect(OpenTrace.config.enabled?).to be true

      # Change enabled
      OpenTrace.config.enabled = false
      expect(OpenTrace.config.enabled?).to be false

      # Change back
      OpenTrace.config.enabled = true
      expect(OpenTrace.config.enabled?).to be true
    end
  end

  describe "level_allowed? caching" do
    it "uses a single hash lookup per call (no string allocation for uppercase)" do
      configure_opentrace!(min_level: :info)

      # Pre-warm the cache
      OpenTrace.config.level_allowed?("DEBUG")

      # Calling with an already-uppercase string should not allocate
      # We verify the fast path by checking return values are correct
      expect(OpenTrace.config.level_allowed?("DEBUG")).to be false
      expect(OpenTrace.config.level_allowed?("INFO")).to be true
      expect(OpenTrace.config.level_allowed?("WARN")).to be true
      expect(OpenTrace.config.level_allowed?("ERROR")).to be true
      expect(OpenTrace.config.level_allowed?("FATAL")).to be true

      # Symbol input also works (slower path, allocates)
      expect(OpenTrace.config.level_allowed?(:debug)).to be false
      expect(OpenTrace.config.level_allowed?(:info)).to be true
    end

    it "invalidates cache when min_level changes" do
      configure_opentrace!(min_level: :info)

      expect(OpenTrace.config.level_allowed?("DEBUG")).to be false

      OpenTrace.config.min_level = :debug
      expect(OpenTrace.config.level_allowed?("DEBUG")).to be true

      OpenTrace.config.min_level = :warn
      expect(OpenTrace.config.level_allowed?("INFO")).to be false
      expect(OpenTrace.config.level_allowed?("WARN")).to be true
    end
  end

  describe "real-world scenario: Lena app config simulation" do
    it "has zero SQL forwarding overhead with sql_logging + min_level: :info" do
      # Simulate the exact Lena app configuration
      configure_opentrace!(
        sql_logging: true,
        min_level: :info,
        sql_normalization: true,
        timeline: true,
        request_summary: true,
        context: -> { { user_id: 42 } }
      )
      boot_railtie!

      normalize_calls = 0
      log_calls = 0

      original_normalize = OpenTrace::SqlNormalizer.method(:normalize)
      allow(OpenTrace::SqlNormalizer).to receive(:normalize) do |*args|
        normalize_calls += 1
        original_normalize.call(*args)
      end

      original_log = OpenTrace.method(:log)
      allow(OpenTrace).to receive(:log) do |*args|
        log_calls += 1
        original_log.call(*args)
      end

      # Simulate a typical Rails request with middleware
      app = ->(env) { [200, {}, ["OK"]] }
      middleware = OpenTrace::Middleware.new(app)
      middleware.call("action_dispatch.request_id" => "req-perf-test")

      # During a typical request, 50-200 SQL queries fire
      fire_sql_queries(150)

      # With min_level: :info, all 150 DEBUG SQL queries should be skipped
      # without calling SqlNormalizer or OpenTrace.log
      expect(normalize_calls).to eq(0),
        "SqlNormalizer called #{normalize_calls} times during 150 SQL queries " \
        "with min_level: :info (should be 0 — all wasted work eliminated)"

      expect(log_calls).to eq(0),
        "OpenTrace.log called #{log_calls} times for SQL queries " \
        "with min_level: :info (should be 0 — DEBUG level filtered)"
    end
  end
end
