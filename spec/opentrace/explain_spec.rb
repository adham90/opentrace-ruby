# frozen_string_literal: true

RSpec.describe "EXPLAIN Plan Capture" do
  describe "config" do
    it "defaults explain_slow_queries to false" do
      config = OpenTrace::Config.new
      expect(config.explain_slow_queries).to be false
    end

    it "defaults explain_threshold_ms to 100.0" do
      config = OpenTrace::Config.new
      expect(config.explain_threshold_ms).to eq(100.0)
    end
  end

  describe "PayloadBuilder EXPLAIN integration" do
    before do
      OpenTrace.reset!
      OpenTrace.configure do |c|
        c.endpoint = "https://opentrace.test"
        c.api_key = "test-key"
        c.service = "test-app"
      end
    end

    after { OpenTrace.shutdown(timeout: 1) }

    it "passes through pending_explains in extra without ActiveRecord" do
      started = Time.now
      finished = started + 0.5

      entry = [
        :request, started, finished, "UsersController", "index",
        "GET", "/users", 200, nil, nil, nil,
        "req-123", "trace-123", "span-123", nil, nil, nil,
        { pending_explains: [{ sql: "SELECT * FROM users", duration_ms: 150.0, name: "User Load" }] }
      ]

      # Without ActiveRecord defined, explain should be skipped
      payload = OpenTrace::PayloadBuilder.materialize(entry, OpenTrace.config)
      expect(payload).to be_a(Hash)
      # Flat format: explain plans would appear in body.queries, not metadata
      expect(payload.dig(:body, :queries)).to be_nil
    end

    it "materializes request without pending_explains" do
      started = Time.now
      finished = started + 0.1

      entry = [
        :request, started, finished, "UsersController", "show",
        "GET", "/users/1", 200, nil, nil, nil,
        "req-456", nil, nil, nil, nil, nil, nil
      ]

      payload = OpenTrace::PayloadBuilder.materialize(entry, OpenTrace.config)
      expect(payload[:message]).to include("GET /users/1 200")
    end

    it "runs pending explains for raw request documents on the background materialization path" do
      result = double("result", rows: [["SCAN users"]])
      connection = double("connection", execute: result)
      pool = double("pool")
      allow(pool).to receive(:with_connection).and_yield(connection)

      stub_const("ActiveRecord", Module.new)
      stub_const("ActiveRecord::Base", double("ActiveRecord::Base", connection_pool: pool))

      doc = {
        started_at: Process.clock_gettime(Process::CLOCK_MONOTONIC),
        request: { method: "GET", path: "/users" },
        response: { status: 200 },
        pending_explains: [{ sql: "SELECT * FROM users", duration_ms: 150.0, name: "User Load" }]
      }

      payload = OpenTrace::PayloadBuilder.materialize([:raw_document, doc], OpenTrace.config)

      expect(payload.dig(:body, :queries).first[:explain_plan]).to eq("SCAN users")
      expect(connection).to have_received(:execute).with("EXPLAIN SELECT * FROM users")
    end
  end

  describe "Middleware cleanup" do
    before do
      OpenTrace.reset!
      OpenTrace.configure do |c|
        c.endpoint = "https://opentrace.test"
        c.api_key = "test-key"
        c.service = "test-app"
        c.flush_interval = 0.2
      end
      stub_request(:any, /opentrace\.test/).to_return(status: 200, body: "{}")
    end

    after { OpenTrace.shutdown(timeout: 1) }

    it "clears pending_explains after request" do
      Fiber[:opentrace_pending_explains] = [{ sql: "SELECT 1", duration_ms: 200, name: "test" }]

      app = ->(_env) { [200, {}, ["OK"]] }
      middleware = OpenTrace::Middleware.new(app)
      middleware.call({})

      expect(Fiber[:opentrace_pending_explains]).to be_nil
    end
  end
end
