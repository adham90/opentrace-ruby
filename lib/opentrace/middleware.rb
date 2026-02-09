# frozen_string_literal: true

module OpenTrace
  class Middleware
    def initialize(app)
      @app = app
    end

    def call(env)
      request_id = env["action_dispatch.request_id"] || env["HTTP_X_REQUEST_ID"]
      OpenTrace.current_request_id = request_id

      @app.call(env)
    ensure
      OpenTrace.current_request_id = nil
    end
  end
end
