# frozen_string_literal: true

require_relative "../../lib/opentrace/runtime_monitor"

RSpec.describe "Full Performance Suite" do
  before do
    OpenTrace.reset!
    OpenTrace.configure do |c|
      c.endpoint = "https://opentrace.test"
      c.api_key = "test-key"
      c.service = "test-app"
      c.flush_interval = 0.2
      c.sql_normalization = true
      c.source_context = true
      c.pii_scrubbing = true
      c.local_vars_capture = true
    end
    stub_request(:any, /opentrace\.test/).to_return(status: 200, body: "{}")
  end

  after { OpenTrace.shutdown(timeout: 1) }

  def measure_ms(iterations = 1000)
    start = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    iterations.times { yield }
    (Process.clock_gettime(Process::CLOCK_MONOTONIC) - start) * 1000
  end

  # ─── Phase 1: Quick Wins ───────────────────────────────────────

  describe "Phase 1: SQL normalization" do
    it "normalizes 1000 queries under 50ms" do
      queries = [
        "SELECT * FROM users WHERE id = 42 AND email = 'alice@example.com'",
        "INSERT INTO logs (msg, level) VALUES ('hello world', 1)",
        "UPDATE users SET name = 'Bob', age = 30 WHERE id = 1",
        "SELECT o.* FROM orders o JOIN users u ON u.id = o.user_id WHERE u.email = 'test@test.com'"
      ]
      elapsed = measure_ms { |i| OpenTrace::SqlNormalizer.normalize(queries[rand(4)]) }
      puts "  SQL normalize 1000x: #{elapsed.round(1)}ms"
      expect(elapsed).to be < 50
    end

    it "fingerprints 1000 queries under 50ms" do
      sql = "SELECT * FROM users WHERE id = 42 AND email = 'alice@example.com'"
      elapsed = measure_ms { OpenTrace::SqlNormalizer.fingerprint(sql) }
      puts "  SQL fingerprint 1000x: #{elapsed.round(1)}ms"
      expect(elapsed).to be < 50
    end
  end

  describe "Phase 1: Exception cause chain" do
    it "builds 5-deep cause chain 1000 times under 50ms" do
      begin
        begin
          begin
            begin
              begin
                raise "level 5"
              rescue; raise "level 4"; end
            rescue; raise "level 3"; end
          rescue; raise "level 2"; end
        rescue; raise "level 1"; end
      rescue => e
        elapsed = measure_ms { OpenTrace.send(:build_cause_chain, e.cause, depth: 0) }
        puts "  Cause chain (5-deep) 1000x: #{elapsed.round(1)}ms"
        expect(elapsed).to be < 50
      end
    end
  end

  describe "Phase 1: Transaction naming" do
    it "set_transaction_name 1000 times under 5ms" do
      elapsed = measure_ms { |i| OpenTrace.set_transaction_name("txn.#{rand(100)}") }
      puts "  Transaction naming 1000x: #{elapsed.round(1)}ms"
      expect(elapsed).to be < 5
    ensure
      Fiber[:opentrace_transaction_name] = nil
    end
  end

  describe "Phase 1: Trace formatter" do
    it "formats 1000 log lines under 50ms" do
      require_relative "../../lib/opentrace/trace_formatter"
      formatter = OpenTrace::TraceFormatter.new(proc { |s, d, p, m| "#{s}: #{m}\n" })
      Fiber[:opentrace_trace_id] = "abc123def456"
      Fiber[:opentrace_request_id] = "req-789"

      elapsed = measure_ms { formatter.call("INFO", Time.now, nil, "Hello world") }
      puts "  Trace formatter 1000x: #{elapsed.round(1)}ms"
      expect(elapsed).to be < 50
    ensure
      Fiber[:opentrace_trace_id] = nil
      Fiber[:opentrace_request_id] = nil
    end
  end

  # ─── Phase 2: Core Instrumentation ─────────────────────────────

  describe "Phase 2: Custom instrumentation (trace)" do
    it "traces 1000 no-op blocks under 100ms" do
      elapsed = measure_ms do
        OpenTrace.trace("test.operation") { |span| 1 + 1 }
      end
      puts "  OpenTrace.trace 1000x: #{elapsed.round(1)}ms"
      expect(elapsed).to be < 100
    end
  end

  describe "Phase 2: Breadcrumbs" do
    it "adds 1000 breadcrumbs under 20ms" do
      elapsed = measure_ms { |i| OpenTrace.add_breadcrumb("nav", "page #{rand(100)}") }
      puts "  add_breadcrumb 1000x: #{elapsed.round(1)}ms"
      expect(elapsed).to be < 20
    ensure
      Fiber[:opentrace_breadcrumbs] = nil
    end
  end

  describe "Phase 2: Source context" do
    it "extracts source context 100 times under 50ms" do
      file = File.expand_path("../../lib/opentrace/version.rb", __dir__)
      line = "#{file}:4:in `<module:OpenTrace>'"

      elapsed = measure_ms(100) { OpenTrace::SourceContext.extract(line) }
      puts "  Source context 100x: #{elapsed.round(1)}ms"
      expect(elapsed).to be < 50
    end
  end

  # ─── Phase 3: Data Quality ─────────────────────────────────────

  describe "Phase 3: PII scrubbing" do
    it "scrubs 1000 hashes under 100ms" do
      elapsed = measure_ms do
        hash = {
          email: "alice@example.com",
          name: "Alice",
          password: "secret123",
          card: "4111 1111 1111 1111",
          message: "User signed up"
        }
        OpenTrace::PiiScrubber.scrub!(hash)
      end
      puts "  PII scrub 1000x: #{elapsed.round(1)}ms"
      expect(elapsed).to be < 100
    end
  end

  describe "Phase 3: Duplicate query detection" do
    it "tracks 1000 queries with fingerprints under 20ms" do
      collector = OpenTrace::RequestCollector.new(max_timeline: 0)
      elapsed = measure_ms do
        collector.record_sql(name: "User Load", duration_ms: 1.0, fingerprint: "fp#{rand(50)}")
      end
      puts "  record_sql with fingerprint 1000x: #{elapsed.round(1)}ms"
      expect(elapsed).to be < 20
    end
  end

  describe "Phase 3: Session tracking middleware" do
    it "extracts session ID 1000 times under 20ms" do
      app = ->(_env) { [200, {}, ["OK"]] }
      middleware = OpenTrace::Middleware.new(app)
      OpenTrace.config.session_tracking = true
      env = { "HTTP_COOKIE" => "_session_id=sess-abc123; other=value" }

      elapsed = measure_ms do
        middleware.send(:extract_session_id, env)
      end
      puts "  Session extraction 1000x: #{elapsed.round(1)}ms"
      expect(elapsed).to be < 20
    end
  end

  # ─── Phase 4: Advanced Features ────────────────────────────────

  describe "Phase 4: Local variables capture" do
    it "captures binding 1000 times under 50ms" do
      user_name = "Alice"
      user_id = 42
      data = { key: "value" }

      elapsed = measure_ms do
        OpenTrace::LocalVars.capture(binding)
      end
      puts "  LocalVars.capture 1000x: #{elapsed.round(1)}ms"
      expect(elapsed).to be < 50
    end
  end

  describe "Phase 4: Runtime monitor metrics collection" do
    it "collects GC stats 100 times under 50ms" do
      elapsed = measure_ms(100) do
        gc = GC.stat
        {
          gc_count: gc[:count],
          gc_major_count: gc[:major_gc_count],
          gc_minor_count: gc[:minor_gc_count],
          gc_heap_live_slots: gc[:heap_live_slots],
          thread_count: Thread.list.count,
          process_pid: Process.pid
        }
      end
      puts "  GC.stat collection 100x: #{elapsed.round(1)}ms"
      expect(elapsed).to be < 50
    end
  end

  # ─── End-to-End: Full request simulation ────────────────────────

  describe "End-to-end: simulated request" do
    it "full middleware + 20 SQL + breadcrumbs + error under 50ms (request thread only)" do
      OpenTrace.config.session_tracking = true
      OpenTrace.config.request_summary = true
      OpenTrace.config.view_tracking = true

      app = lambda do |_env|
        # Simulate breadcrumbs
        5.times { |i| OpenTrace.add_breadcrumb("nav", "page_#{i}") }

        # Simulate SQL queries (just record_sql, not real DB)
        collector = Fiber[:opentrace_collector]
        if collector
          20.times { |i| collector.record_sql(name: "User Load", duration_ms: 0.5, fingerprint: "fp#{i % 5}") }
          3.times { |i| collector.record_view(template: "users/show.html.erb", duration_ms: 1.0) }
        end

        # Simulate transaction naming
        OpenTrace.set_transaction_name("GET /users")

        [200, {}, ["OK"]]
      end

      middleware = OpenTrace::Middleware.new(app)
      env = {
        "HTTP_COOKIE" => "_session_id=perf-test-session",
        "action_dispatch.request_id" => "perf-req-001"
      }

      elapsed = measure_ms(100) do
        middleware.call(env.dup)
      end
      avg_ms = elapsed / 100.0
      puts "  Full request simulation avg: #{avg_ms.round(3)}ms (100 iterations, #{elapsed.round(1)}ms total)"
      expect(avg_ms).to be < 0.5 # Should be well under 500μs per request
    end
  end

  # ─── OpenTrace.log hot path ─────────────────────────────────────

  describe "Hot path: OpenTrace.log" do
    it "enqueues 1000 log calls under 100ms (request thread only)" do
      # Stub enqueue to isolate request-thread cost
      allow_any_instance_of(OpenTrace::Client).to receive(:enqueue)

      elapsed = measure_ms do
        OpenTrace.log("INFO", "test message", { user_id: 42, action: "test" })
      end
      puts "  OpenTrace.log 1000x: #{elapsed.round(1)}ms"
      expect(elapsed).to be < 100
    end
  end

  describe "Hot path: OpenTrace.error" do
    it "processes 100 error calls under 50ms (request thread only)" do
      error = RuntimeError.new("test error")
      error.set_backtrace([
        "app/controllers/users_controller.rb:42:in `index'",
        "lib/middleware/auth.rb:10:in `call'"
      ])

      # Stub enqueue to isolate request-thread cost from background thread
      allow_any_instance_of(OpenTrace::Client).to receive(:enqueue)

      elapsed = measure_ms(100) do
        OpenTrace.error(error, { user_id: 42 })
      end
      puts "  OpenTrace.error 100x: #{elapsed.round(1)}ms"
      expect(elapsed).to be < 50
    end
  end

  # ─── PayloadBuilder materialization (background thread) ─────────

  describe "Background: PayloadBuilder materialization" do
    it "materializes 1000 log entries under 200ms" do
      entry = [
        Time.now.to_f, "INFO", "test message",
        { user_id: 42, action: "test" },
        { hostname: "web1" }, "req-001", "trace-001", "span-001", nil, nil, nil
      ].freeze

      elapsed = measure_ms do
        OpenTrace::PayloadBuilder.materialize(entry, OpenTrace.config)
      end
      puts "  PayloadBuilder.materialize (log) 1000x: #{elapsed.round(1)}ms"
      expect(elapsed).to be < 200
    end

    it "materializes 100 request entries under 100ms" do
      started = Time.now
      finished = started + 0.15
      collector = OpenTrace::RequestCollector.new(max_timeline: 0)
      10.times { collector.record_sql(name: "User Load", duration_ms: 1.0, fingerprint: "fp1") }

      entry = [
        :request, started, finished, "UsersController", "index",
        "GET", "/users", 200, nil, nil, nil,
        "req-001", "trace-001", "span-001", nil,
        { user_id: 42 }, collector, { transaction_name: "GET /users" }
      ].freeze

      elapsed = measure_ms(100) do
        OpenTrace::PayloadBuilder.materialize(entry, OpenTrace.config)
      end
      puts "  PayloadBuilder.materialize (request) 100x: #{elapsed.round(1)}ms"
      expect(elapsed).to be < 100
    end
  end
end
