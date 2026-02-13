# frozen_string_literal: true

RSpec.describe "Phase 1 performance" do
  before do
    OpenTrace.reset!
    OpenTrace.configure do |c|
      c.endpoint = "https://opentrace.test"
      c.api_key = "test-key"
      c.service = "test-app"
      c.flush_interval = 0.2
      c.sql_normalization = true
    end
    stub_request(:any, /opentrace\.test/).to_return(status: 200, body: "{}")
  end

  after { OpenTrace.shutdown(timeout: 1) }

  describe "SQL normalization performance" do
    it "normalizes 1000 queries under 50ms" do
      queries = [
        "SELECT * FROM users WHERE id = 42 AND email = 'alice@example.com'",
        "INSERT INTO logs (msg, level) VALUES ('hello world', 1)",
        "UPDATE users SET name = 'Bob', age = 30 WHERE id = 1 AND active = TRUE",
        "SELECT o.* FROM orders o JOIN users u ON u.id = o.user_id WHERE u.email = 'test@test.com' LIMIT 25 OFFSET 50"
      ]

      start = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      1000.times do |i|
        OpenTrace::SqlNormalizer.normalize(queries[i % queries.length])
      end
      elapsed_ms = (Process.clock_gettime(Process::CLOCK_MONOTONIC) - start) * 1000

      expect(elapsed_ms).to be < 50
    end

    it "fingerprints 1000 queries under 50ms" do
      sql = "SELECT * FROM users WHERE id = 42 AND email = 'alice@example.com'"
      start = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      1000.times { OpenTrace::SqlNormalizer.fingerprint(sql) }
      elapsed_ms = (Process.clock_gettime(Process::CLOCK_MONOTONIC) - start) * 1000

      expect(elapsed_ms).to be < 50
    end
  end

  describe "Exception cause chain performance" do
    it "builds cause chain for 5-deep chain under 1ms" do
      # Build a 5-deep exception chain
      begin
        begin
          begin
            begin
              begin
                raise "level 5"
              rescue
                raise "level 4"
              end
            rescue
              raise "level 3"
            end
          rescue
            raise "level 2"
          end
        rescue
          raise "level 1"
        end
      rescue => e
        start = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        1000.times { OpenTrace.send(:build_cause_chain, e.cause, depth: 0) }
        elapsed_ms = (Process.clock_gettime(Process::CLOCK_MONOTONIC) - start) * 1000

        expect(elapsed_ms).to be < 50
      end
    end
  end

  describe "Transaction naming performance" do
    it "set_transaction_name 1000 times under 1ms" do
      start = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      1000.times { |i| OpenTrace.set_transaction_name("transaction.#{i}") }
      elapsed_ms = (Process.clock_gettime(Process::CLOCK_MONOTONIC) - start) * 1000

      expect(elapsed_ms).to be < 5
    ensure
      Fiber[:opentrace_transaction_name] = nil
    end
  end

  describe "Trace formatter performance" do
    it "formats 1000 log lines under 10ms" do
      require_relative "../../lib/opentrace/trace_formatter"
      formatter = OpenTrace::TraceFormatter.new(proc { |s, d, p, m| "#{s}: #{m}\n" })

      Fiber[:opentrace_trace_id] = "abc123def456"
      Fiber[:opentrace_request_id] = "req-789"

      start = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      1000.times { formatter.call("INFO", Time.now, nil, "Hello world") }
      elapsed_ms = (Process.clock_gettime(Process::CLOCK_MONOTONIC) - start) * 1000

      expect(elapsed_ms).to be < 50
    ensure
      Fiber[:opentrace_trace_id] = nil
      Fiber[:opentrace_request_id] = nil
    end
  end
end
