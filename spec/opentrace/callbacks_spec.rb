# frozen_string_literal: true

RSpec.describe "Lifecycle callbacks" do
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

  describe "on_error callback" do
    it "fires when OpenTrace.error is called" do
      callback_called = false
      callback_exception = nil
      callback_meta = nil

      OpenTrace.configure do |c|
        c.endpoint = "https://opentrace.test"
        c.api_key = "test-key"
        c.service = "test-app"
        c.flush_interval = 0.2
        c.on_error = ->(exception, meta) {
          callback_called = true
          callback_exception = exception
          callback_meta = meta
        }
      end

      error = RuntimeError.new("test error")
      OpenTrace.error(error, { extra: "data" })

      expect(callback_called).to be true
      expect(callback_exception).to eq(error)
      expect(callback_meta[:exception_class]).to eq("RuntimeError")
      expect(callback_meta[:extra]).to eq("data")
    end

    it "does not break error logging if callback raises" do
      OpenTrace.configure do |c|
        c.endpoint = "https://opentrace.test"
        c.api_key = "test-key"
        c.service = "test-app"
        c.flush_interval = 0.2
        c.on_error = ->(_exc, _meta) { raise "callback error" }
      end

      # Should not raise
      expect {
        OpenTrace.error(RuntimeError.new("test"))
      }.not_to raise_error
    end

    it "does not fire when on_error is nil" do
      OpenTrace.config.on_error = nil
      # Should not raise
      expect {
        OpenTrace.error(RuntimeError.new("test"))
      }.not_to raise_error
    end
  end

  describe "after_send callback" do
    it "is configured as a proc" do
      after_send_called = false

      OpenTrace.configure do |c|
        c.endpoint = "https://opentrace.test"
        c.api_key = "test-key"
        c.service = "test-app"
        c.flush_interval = 0.2
        c.after_send = ->(batch_size, bytes) {
          after_send_called = true
        }
      end

      # after_send is called on the background thread — just verify config
      expect(OpenTrace.config.after_send).to be_a(Proc)
    end
  end

  describe "before_breadcrumb callback" do
    it "filters breadcrumbs" do
      OpenTrace.configure do |c|
        c.endpoint = "https://opentrace.test"
        c.api_key = "test-key"
        c.service = "test-app"
        c.flush_interval = 0.2
        c.before_breadcrumb = ->(crumb) {
          crumb.category == "secret" ? nil : crumb
        }
      end

      OpenTrace.add_breadcrumb("secret", "hidden data")
      OpenTrace.add_breadcrumb("normal", "visible data")

      crumbs = OpenTrace.current_breadcrumbs
      expect(crumbs.length).to eq(1)
      expect(crumbs[0][:category]).to eq("normal")
    ensure
      Fiber[:opentrace_breadcrumbs] = nil
    end

    it "handles callback errors gracefully" do
      OpenTrace.configure do |c|
        c.endpoint = "https://opentrace.test"
        c.api_key = "test-key"
        c.service = "test-app"
        c.flush_interval = 0.2
        c.before_breadcrumb = ->(_crumb) { raise "callback error" }
      end

      # Should not raise, and breadcrumb should be added (fallback)
      expect {
        OpenTrace.add_breadcrumb("test", "data")
      }.not_to raise_error

      crumbs = OpenTrace.current_breadcrumbs
      expect(crumbs.length).to eq(1)
    ensure
      Fiber[:opentrace_breadcrumbs] = nil
    end
  end
end
