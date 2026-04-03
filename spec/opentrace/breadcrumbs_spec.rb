# frozen_string_literal: true

RSpec.describe "Breadcrumbs API" do
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
    Fiber[:opentrace_breadcrumbs] = nil
    OpenTrace.shutdown(timeout: 1)
  end

  describe OpenTrace::Breadcrumb do
    it "stores category, message, data, and level" do
      crumb = described_class.new(
        category: "auth",
        message: "User logged in",
        data: { user_id: 42 },
        level: "info"
      )
      expect(crumb.category).to eq("auth")
      expect(crumb.message).to eq("User logged in")
      expect(crumb.data).to eq({ user_id: 42 })
      expect(crumb.level).to eq("info")
    end

    it "records a float timestamp" do
      crumb = described_class.new(category: "test", message: "msg")
      expect(crumb.timestamp).to be_a(Float)
    end

    it "converts to a hash" do
      crumb = described_class.new(category: "auth", message: "login", data: { user: 1 })
      h = crumb.to_h
      expect(h[:category]).to eq("auth")
      expect(h[:message]).to eq("login")
      expect(h[:data]).to eq({ user: 1 })
      expect(h[:timestamp]).to be_a(Float)
    end

    it "omits data from hash when nil" do
      crumb = described_class.new(category: "test", message: "msg")
      h = crumb.to_h
      expect(h).not_to have_key(:data)
    end
  end

  describe OpenTrace::BreadcrumbBuffer do
    it "starts empty" do
      buffer = described_class.new
      expect(buffer.empty?).to be true
      expect(buffer.size).to eq(0)
    end

    it "adds breadcrumbs" do
      buffer = described_class.new
      crumb = OpenTrace::Breadcrumb.new(category: "test", message: "msg")
      buffer.add(crumb)
      expect(buffer.size).to eq(1)
    end

    it "caps at 25 breadcrumbs (FIFO)" do
      buffer = described_class.new
      30.times do |i|
        buffer.add(OpenTrace::Breadcrumb.new(category: "test", message: "msg #{i}"))
      end
      expect(buffer.size).to eq(25)
      # First 5 should have been evicted
      arr = buffer.to_a
      expect(arr.first[:message]).to eq("msg 5")
      expect(arr.last[:message]).to eq("msg 29")
    end

    it "returns array of hashes from to_a" do
      buffer = described_class.new
      buffer.add(OpenTrace::Breadcrumb.new(category: "a", message: "m1"))
      buffer.add(OpenTrace::Breadcrumb.new(category: "b", message: "m2"))
      arr = buffer.to_a
      expect(arr.length).to eq(2)
      expect(arr[0][:category]).to eq("a")
      expect(arr[1][:category]).to eq("b")
    end
  end

  describe "OpenTrace.add_breadcrumb" do
    it "adds a breadcrumb to the current Fiber-local buffer" do
      OpenTrace.add_breadcrumb("auth", "User logged in", { user_id: 42 })
      crumbs = OpenTrace.current_breadcrumbs
      expect(crumbs.length).to eq(1)
      expect(crumbs[0][:category]).to eq("auth")
      expect(crumbs[0][:message]).to eq("User logged in")
    end

    it "adds multiple breadcrumbs in order" do
      OpenTrace.add_breadcrumb("step", "Step 1")
      OpenTrace.add_breadcrumb("step", "Step 2")
      OpenTrace.add_breadcrumb("step", "Step 3")
      crumbs = OpenTrace.current_breadcrumbs
      expect(crumbs.length).to eq(3)
      expect(crumbs.map { |c| c[:message] }).to eq(["Step 1", "Step 2", "Step 3"])
    end

    it "does nothing when disabled" do
      OpenTrace.disable!
      OpenTrace.add_breadcrumb("test", "should not appear")
      expect(OpenTrace.current_breadcrumbs).to be_empty
    end
  end

  describe "OpenTrace.current_breadcrumbs" do
    it "returns empty array when no breadcrumbs" do
      expect(OpenTrace.current_breadcrumbs).to eq([])
    end
  end

  describe "before_breadcrumb callback" do
    it "allows filtering breadcrumbs" do
      OpenTrace.configure do |c|
        c.endpoint = "https://opentrace.test"
        c.api_key = "test-key"
        c.service = "test-app"
        c.flush_interval = 0.2
        c.before_breadcrumb = ->(crumb) {
          crumb.category == "sensitive" ? nil : crumb
        }
      end

      OpenTrace.add_breadcrumb("sensitive", "secret data")
      OpenTrace.add_breadcrumb("normal", "public data")
      crumbs = OpenTrace.current_breadcrumbs
      expect(crumbs.length).to eq(1)
      expect(crumbs[0][:category]).to eq("normal")
    end
  end

  describe "breadcrumbs attached to errors" do
    it "attaches breadcrumbs to error payloads" do
      OpenTrace.add_breadcrumb("checkout", "Started")
      OpenTrace.add_breadcrumb("checkout", "Payment initiated")

      enqueued = []
      allow_any_instance_of(OpenTrace::Client).to receive(:enqueue) { |_, doc| enqueued << doc }

      OpenTrace.error(RuntimeError.new("payment failed"))

      expect(enqueued.size).to eq(1)
      meta = enqueued[0][:event][:metadata]
      expect(meta[:breadcrumbs]).to be_an(Array)
      expect(meta[:breadcrumbs].length).to eq(2)
      expect(meta[:breadcrumbs][0][:category]).to eq("checkout")
    end

    it "does not attach breadcrumbs when buffer is empty" do
      enqueued = []
      allow_any_instance_of(OpenTrace::Client).to receive(:enqueue) { |_, doc| enqueued << doc }

      OpenTrace.error(RuntimeError.new("error"))

      expect(enqueued.size).to eq(1)
      meta = enqueued[0][:event][:metadata]
      expect(meta).not_to have_key(:breadcrumbs)
    end
  end

  describe "middleware cleanup" do
    it "clears breadcrumbs after request" do
      app = ->(_env) { [200, {}, ["OK"]] }
      middleware = OpenTrace::Middleware.new(app)

      Fiber[:opentrace_breadcrumbs] = OpenTrace::BreadcrumbBuffer.new
      Fiber[:opentrace_breadcrumbs].add(OpenTrace::Breadcrumb.new(category: "test", message: "msg"))

      middleware.call({})
      expect(Fiber[:opentrace_breadcrumbs]).to be_nil
    end
  end
end
