# frozen_string_literal: true

RSpec.describe "Custom transaction naming" do
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

  after do
    Fiber[:opentrace_transaction_name] = nil
    OpenTrace.shutdown(timeout: 1)
  end

  describe "OpenTrace.set_transaction_name" do
    it "sets the transaction name in Fiber-local storage" do
      OpenTrace.set_transaction_name("checkout.complete")
      expect(Fiber[:opentrace_transaction_name]).to eq("checkout.complete")
    end

    it "converts non-string values to strings" do
      OpenTrace.set_transaction_name(:api_orders_create)
      expect(Fiber[:opentrace_transaction_name]).to eq("api_orders_create")
    end

    it "overwrites previous transaction name" do
      OpenTrace.set_transaction_name("first")
      OpenTrace.set_transaction_name("second")
      expect(Fiber[:opentrace_transaction_name]).to eq("second")
    end
  end

  describe "OpenTrace.current_transaction_name" do
    it "returns nil when not set" do
      expect(OpenTrace.current_transaction_name).to be_nil
    end

    it "returns the current transaction name" do
      OpenTrace.set_transaction_name("my.transaction")
      expect(OpenTrace.current_transaction_name).to eq("my.transaction")
    end
  end

  describe "PayloadBuilder integration" do
    it "uses transaction name in message when present" do
      entry = [
        :request,
        Time.now - 0.1, Time.now,
        "OrdersController", "create", "POST", "/orders",
        200, nil, nil, nil,
        "req-123", "trace-456", "span-789", nil,
        nil, nil,
        { transaction_name: "checkout.create" }
      ].freeze

      config = OpenTrace.config
      payload = OpenTrace::PayloadBuilder.materialize(entry, config)

      expect(payload[:message]).to start_with("checkout.create 200")
      # Flat format: transaction_name lives in body.context
      expect(payload.dig(:body, :context, :transaction_name)).to eq("checkout.create")
    end

    it "uses default method/path message when no transaction name" do
      entry = [
        :request,
        Time.now - 0.1, Time.now,
        "OrdersController", "create", "POST", "/orders",
        200, nil, nil, nil,
        "req-123", "trace-456", "span-789", nil,
        nil, nil, nil
      ].freeze

      config = OpenTrace.config
      payload = OpenTrace::PayloadBuilder.materialize(entry, config)

      expect(payload[:message]).to start_with("POST /orders 200")
      # Flat format: body.context should not contain transaction_name
      context = payload.dig(:body, :context)
      if context
        expect(context).not_to have_key(:transaction_name)
      end
    end
  end

  describe "Middleware cleanup" do
    it "clears transaction name after request" do
      app = ->(_env) { [200, {}, ["OK"]] }
      middleware = OpenTrace::Middleware.new(app)

      Fiber[:opentrace_transaction_name] = "test.transaction"
      middleware.call({})
      expect(Fiber[:opentrace_transaction_name]).to be_nil
    end
  end
end
