# frozen_string_literal: true

RSpec.describe "Session tracking" do
  before do
    OpenTrace.reset!
    OpenTrace.configure do |c|
      c.endpoint = "https://opentrace.test"
      c.api_key = "test-key"
      c.service = "test-app"
      c.flush_interval = 0.2
      c.session_tracking = true
    end
    stub_request(:any, /opentrace\.test/).to_return(status: 200, body: "{}")
  end

  after do
    Fiber[:opentrace_session_id] = nil
    OpenTrace.shutdown(timeout: 1)
  end

  describe "middleware session extraction" do
    let(:app) { ->(_env) { [200, {}, ["OK"]] } }
    let(:middleware) { OpenTrace::Middleware.new(app) }

    it "extracts session_id from rack session" do
      session = double("session", id: "sess-abc123")
      env = { "rack.session" => session }

      captured_session_id = nil
      inner_app = ->(_e) {
        captured_session_id = Fiber[:opentrace_session_id]
        [200, {}, ["OK"]]
      }
      mw = OpenTrace::Middleware.new(inner_app)
      mw.call(env)

      expect(captured_session_id).to eq("sess-abc123")
    end

    it "extracts session_id from cookie" do
      env = { "HTTP_COOKIE" => "_session_id=cookie-session-xyz; other=value" }

      captured_session_id = nil
      inner_app = ->(_e) {
        captured_session_id = Fiber[:opentrace_session_id]
        [200, {}, ["OK"]]
      }
      mw = OpenTrace::Middleware.new(inner_app)
      mw.call(env)

      expect(captured_session_id).to eq("cookie-session-xyz")
    end

    it "uses custom cookie name from rack session options" do
      env = {
        "rack.session.options" => { key: "_my_app_session" },
        "HTTP_COOKIE" => "_my_app_session=custom-sess-id; other=val"
      }

      captured_session_id = nil
      inner_app = ->(_e) {
        captured_session_id = Fiber[:opentrace_session_id]
        [200, {}, ["OK"]]
      }
      mw = OpenTrace::Middleware.new(inner_app)
      mw.call(env)

      expect(captured_session_id).to eq("custom-sess-id")
    end

    it "returns nil when no session is available" do
      env = {}

      captured_session_id = :not_set
      inner_app = ->(_e) {
        captured_session_id = Fiber[:opentrace_session_id]
        [200, {}, ["OK"]]
      }
      mw = OpenTrace::Middleware.new(inner_app)
      mw.call(env)

      expect(captured_session_id).to be_nil
    end

    it "clears session_id after request" do
      Fiber[:opentrace_session_id] = "old-session"
      middleware.call({})
      expect(Fiber[:opentrace_session_id]).to be_nil
    end

    it "does not extract session when session_tracking is disabled" do
      OpenTrace.config.session_tracking = false
      env = { "HTTP_COOKIE" => "_session_id=should-not-capture" }

      captured_session_id = :not_set
      inner_app = ->(_e) {
        captured_session_id = Fiber[:opentrace_session_id]
        [200, {}, ["OK"]]
      }
      mw = OpenTrace::Middleware.new(inner_app)
      mw.call(env)

      expect(captured_session_id).to be_nil
    end
  end
end
