# frozen_string_literal: true

RSpec.describe OpenTrace::PayloadBuilder do
  let(:config) do
    OpenTrace::Config.new.tap do |c|
      c.endpoint = "https://opentrace.test"
      c.api_key = "test-key"
      c.service = "test-service"
      c.environment = "test"
    end
  end

  before do
    configure_opentrace!
  end

  describe ".materialize" do
    it "materializes a log array into a payload hash" do
      ts = Process.clock_gettime(Process::CLOCK_REALTIME)
      entry = [
        ts, "INFO", "test message", { user_id: 42 },
        nil, "req-1", nil, nil, nil, nil, nil
      ].freeze

      payload = described_class.materialize(entry, OpenTrace.config)

      expect(payload[:level]).to eq("INFO")
      expect(payload[:message]).to eq("test message")
      expect(payload[:service]).to eq("test-service")
      expect(payload[:environment]).to eq("test")
      expect(payload[:metadata][:user_id]).to eq(42)
      expect(payload[:request_id]).to eq("req-1")
      expect(payload[:metadata]).not_to have_key(:request_id)
      expect(payload[:timestamp]).to match(/\A\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d{6}Z\z/)
    end

    it "passes through legacy Hash payloads unchanged" do
      legacy = { timestamp: "2026-01-01", level: "INFO", message: "legacy" }
      expect(described_class.materialize(legacy, config)).to eq(legacy)
    end

    it "returns nil for unrecognized types" do
      expect(described_class.materialize("bad", config)).to be_nil
    end

    it "handles nil entry gracefully" do
      expect(described_class.materialize(nil, config)).to be_nil
    end
  end

  describe ".materialize_log" do
    it "includes event_type for events" do
      entry = [
        Process.clock_gettime(Process::CLOCK_REALTIME),
        "INFO", "payment completed", { amount: 99 },
        nil, nil, nil, nil, nil, nil, "payment.completed"
      ]

      payload = described_class.materialize(entry, OpenTrace.config)

      expect(payload[:event_type]).to eq("payment.completed")
    end

    it "extracts trace_id from metadata if user provided it" do
      entry = [
        Process.clock_gettime(Process::CLOCK_REALTIME),
        "INFO", "traced", { trace_id: "user-trace-123", other: "val" },
        nil, nil, nil, nil, nil, nil, nil
      ]

      payload = described_class.materialize(entry, OpenTrace.config)

      expect(payload[:trace_id]).to eq("user-trace-123")
      expect(payload[:metadata]).not_to have_key(:trace_id)
      expect(payload[:metadata][:other]).to eq("val")
    end

    it "prefers metadata trace_id over Fiber-local trace_id" do
      entry = [
        Process.clock_gettime(Process::CLOCK_REALTIME),
        "INFO", "traced", { trace_id: "from-meta" },
        nil, nil, "from-fiber", nil, nil, nil, nil
      ]

      payload = described_class.materialize(entry, OpenTrace.config)

      expect(payload[:trace_id]).to eq("from-meta")
    end

    it "uses Fiber-local trace_id when metadata has none" do
      entry = [
        Process.clock_gettime(Process::CLOCK_REALTIME),
        "INFO", "traced", {},
        nil, nil, "from-fiber", nil, nil, nil, nil
      ]

      payload = described_class.materialize(entry, OpenTrace.config)

      expect(payload[:trace_id]).to eq("from-fiber")
    end

    it "includes span_id and parent_span_id" do
      entry = [
        Process.clock_gettime(Process::CLOCK_REALTIME),
        "INFO", "spans", {},
        nil, nil, "trace-1", "span-1", "parent-1", nil, nil
      ]

      payload = described_class.materialize(entry, OpenTrace.config)

      expect(payload[:span_id]).to eq("span-1")
      expect(payload[:parent_span_id]).to eq("parent-1")
    end

    it "uses cached context from frozen Hash" do
      ctx = { user_id: 42, tenant: "acme" }.freeze
      entry = [
        Process.clock_gettime(Process::CLOCK_REALTIME),
        "INFO", "with context", {},
        ctx, nil, nil, nil, nil, nil, nil
      ]

      payload = described_class.materialize(entry, OpenTrace.config)

      expect(payload[:metadata][:user_id]).to eq(42)
      expect(payload[:metadata][:tenant]).to eq("acme")
    end

    it "merges caller metadata over context" do
      ctx = { user_id: 1 }.freeze
      entry = [
        Process.clock_gettime(Process::CLOCK_REALTIME),
        "INFO", "override", { user_id: 99 },
        ctx, nil, nil, nil, nil, nil, nil
      ]

      payload = described_class.materialize(entry, OpenTrace.config)

      expect(payload[:metadata][:user_id]).to eq(99)
    end

    it "includes static context (hostname, pid)" do
      entry = [
        Process.clock_gettime(Process::CLOCK_REALTIME),
        "INFO", "static", {},
        nil, nil, nil, nil, nil, nil, nil
      ]

      payload = described_class.materialize(entry, OpenTrace.config)

      expect(payload[:metadata][:hostname]).to be_a(String)
      expect(payload[:metadata][:pid]).to be_a(Integer)
    end

    it "compacts nil metadata values" do
      entry = [
        Process.clock_gettime(Process::CLOCK_REALTIME),
        "INFO", "compacted", { key: nil, present: "yes" },
        nil, nil, nil, nil, nil, nil, nil
      ]

      payload = described_class.materialize(entry, OpenTrace.config)

      expect(payload[:metadata]).not_to have_key(:key)
      expect(payload[:metadata][:present]).to eq("yes")
    end
  end

  describe ".materialize_request" do
    let(:started) { Time.now - 0.1 }
    let(:finished) { Time.now }

    it "materializes a :request array into a payload hash" do
      entry = [
        :request, started, finished,
        "UsersController", "show", "GET", "/users/1", 200,
        nil, nil, nil,  # no exception
        "req-1", nil, nil, nil,  # request_id, trace_id, span_id, parent_span_id
        nil, nil, nil  # cached_ctx, collector, extra
      ].freeze

      payload = described_class.materialize(entry, OpenTrace.config)

      expect(payload[:level]).to eq("INFO")
      expect(payload[:message]).to match(%r{GET /users/1 200})
      expect(payload[:metadata][:controller]).to eq("UsersController")
      expect(payload[:metadata][:action]).to eq("show")
      expect(payload[:metadata][:method]).to eq("GET")
      expect(payload[:metadata][:path]).to eq("/users/1")
      expect(payload[:metadata][:status]).to eq(200)
      expect(payload[:request_id]).to eq("req-1")
      expect(payload[:metadata]).not_to have_key(:request_id)
    end

    it "sets ERROR level for exceptions" do
      entry = [
        :request, started, finished,
        "UsersController", "show", "GET", "/users/1", 500,
        "RuntimeError", "boom", ["app/models/user.rb:1:in `find'"],
        "req-1", nil, nil, nil,
        nil, nil, nil
      ].freeze

      payload = described_class.materialize(entry, OpenTrace.config)

      expect(payload[:level]).to eq("ERROR")
      expect(payload[:exception_class]).to eq("RuntimeError")
      expect(payload[:metadata][:exception_message]).to eq("boom")
      expect(payload[:metadata][:backtrace]).to be_a(Array)
      expect(payload[:error_fingerprint]).to be_a(String)
      expect(payload[:source_file]).to eq("app/models/user.rb")
      expect(payload[:source_line]).to eq(1)
    end

    it "sets WARN level for 4xx status" do
      entry = [
        :request, started, finished,
        "UsersController", "show", "GET", "/users/1", 404,
        nil, nil, nil,
        nil, nil, nil, nil,
        nil, nil, nil
      ].freeze

      payload = described_class.materialize(entry, OpenTrace.config)

      expect(payload[:level]).to eq("WARN")
    end

    it "includes request_summary from collector" do
      collector = OpenTrace::RequestCollector.new(max_timeline: 0)
      collector.record_sql(name: "User Load", duration_ms: 5.0)
      collector.record_sql(name: "Post Load", duration_ms: 3.0)

      entry = [
        :request, started, finished,
        "UsersController", "index", "GET", "/users", 200,
        nil, nil, nil,
        nil, nil, nil, nil,
        nil, collector, nil
      ].freeze

      payload = described_class.materialize(entry, OpenTrace.config)

      expect(payload[:request_summary]).to be_a(Hash)
      expect(payload[:request_summary][:sql_count]).to eq(2)
      expect(payload[:request_summary][:controller]).to eq("UsersController")
    end

    it "includes extra metadata (SQL counters) when no collector" do
      extra = { sql_query_count: 5, sql_total_ms: 12.3 }

      entry = [
        :request, started, finished,
        "UsersController", "index", "GET", "/users", 200,
        nil, nil, nil,
        nil, nil, nil, nil,
        nil, nil, extra
      ].freeze

      payload = described_class.materialize(entry, OpenTrace.config)

      expect(payload[:metadata][:sql_query_count]).to eq(5)
      expect(payload[:metadata][:sql_total_ms]).to eq(12.3)
    end

    it "includes context data (user_id) in metadata from cached_ctx" do
      cached_ctx = { user_id: 42, tenant: "acme" }

      entry = [
        :request, started, finished,
        "UsersController", "show", "GET", "/users/1", 200,
        nil, nil, nil,
        "req-1", nil, nil, nil,
        cached_ctx, nil, nil
      ].freeze

      payload = described_class.materialize(entry, OpenTrace.config)

      expect(payload[:metadata][:user_id]).to eq(42)
      expect(payload[:metadata][:tenant]).to eq("acme")
      expect(payload[:request_id]).to eq("req-1")
      expect(payload[:metadata]).not_to have_key(:request_id)
    end

    it "merges extra over cached_ctx without losing context" do
      cached_ctx = { user_id: 42 }
      extra = { sql_query_count: 3 }

      entry = [
        :request, started, finished,
        "UsersController", "show", "GET", "/users/1", 200,
        nil, nil, nil,
        nil, nil, nil, nil,
        cached_ctx, nil, extra
      ].freeze

      payload = described_class.materialize(entry, OpenTrace.config)

      expect(payload[:metadata][:user_id]).to eq(42)
      expect(payload[:metadata][:sql_query_count]).to eq(3)
    end

    it "handles nil cached_ctx gracefully" do
      entry = [
        :request, started, finished,
        "UsersController", "show", "GET", "/users/1", 200,
        nil, nil, nil,
        "req-1", nil, nil, nil,
        nil, nil, nil
      ].freeze

      payload = described_class.materialize(entry, OpenTrace.config)

      expect(payload[:request_id]).to eq("req-1")
      expect(payload[:metadata]).not_to have_key(:user_id)
    end
  end
end
