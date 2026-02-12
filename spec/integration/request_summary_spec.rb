# frozen_string_literal: true

require "stringio"
require "securerandom"

require_relative "rails_spec_helper"

RSpec.describe "Request summary with RequestCollector" do
  before do
    configure_opentrace!(view_tracking: true, cache_tracking: true, timeline: true)
    stub_request(:post, "https://opentrace.test/api/logs")
      .to_return(status: 201, body: '{"count":1}')
    ActiveSupport::Notifications.reset!

    Rails.logger = ::Logger.new(StringIO.new)
    app = Rails::Application.new
    app.config.logger = ::Logger.new(StringIO.new)
    OpenTrace::Railtie.initializer_blocks.each { |block| block.call(app) }
    OpenTrace::Railtie.config.after_initialize_blocks.each { |block| block.call(app) }
  end

  # Find the controller request log (not individual SQL/view logs) from any batch.
  # With Plan 6, controller may be in request_summary (when collector is active)
  # or in metadata (fallback without collector).
  def find_request_log(req)
    json = decompress_body(req.body)
    logs = JSON.parse(json)
    logs = [logs] unless logs.is_a?(Array)
    logs.find { |l|
      l["request_summary"]&.key?("controller") ||
        l["metadata"]&.key?("controller")
    }
  end

  def simulate_request_with_collector(controller: "OrdersController", action: "show", status: 200, &block)
    # Set up Fiber-locals like the middleware would
    OpenTrace.current_request_id = "req-summary-test"
    Fiber[:opentrace_sql_count] = 0
    Fiber[:opentrace_sql_total_ms] = 0.0
    require "opentrace/request_collector"
    Fiber[:opentrace_collector] = OpenTrace::RequestCollector.new

    # Fire events inside the "request"
    block&.call

    headers = Struct.new(:env).new({
      "action_dispatch.request_id" => "req-summary-test"
    })

    # Fire the controller notification (sleep ensures non-zero duration for time_breakdown)
    ActiveSupport::Notifications.instrument("process_action.action_controller", {
      controller: controller,
      action: action,
      method: "GET",
      path: "/orders/1",
      status: status,
      headers: headers
    }) { sleep 0.001 }
  ensure
    Fiber[:opentrace_collector] = nil
    Fiber[:opentrace_cached_context] = nil
    Fiber[:opentrace_sql_count] = nil
    Fiber[:opentrace_sql_total_ms] = nil
    OpenTrace.current_request_id = nil
  end

  it "includes SQL summary from collector in request log" do
    simulate_request_with_collector do
      3.times do
        ActiveSupport::Notifications.instrument("sql.active_record", {
          name: "User Load",
          sql: "SELECT * FROM users WHERE id = 1",
          cached: false
        }) { sleep 0.001 }
      end
    end
    sleep 0.5

    expect(
      a_request(:post, "https://opentrace.test/api/logs")
        .with { |req|
          body = find_request_log(req)
          next false unless body

          rs = body["request_summary"]
          rs &&
            rs["sql_count"] == 3 &&
            rs["sql_total_ms"].is_a?(Numeric) &&
            rs["sql_slowest_name"] == "User Load"
        }
    ).to have_been_made
  end

  it "includes view render summary from collector" do
    simulate_request_with_collector do
      ActiveSupport::Notifications.instrument("render_template.action_view", {
        identifier: "/app/views/orders/show.html.erb"
      }) { sleep 0.001 }

      3.times do
        ActiveSupport::Notifications.instrument("render_partial.action_view", {
          identifier: "/app/views/orders/_item.html.erb"
        }) { sleep 0.001 }
      end
    end
    sleep 0.5

    expect(
      a_request(:post, "https://opentrace.test/api/logs")
        .with { |req|
          body = find_request_log(req)
          next false unless body

          rs = body["request_summary"]
          rs &&
            rs["view_count"] == 4 &&
            rs["view_total_ms"].is_a?(Numeric) &&
            rs["view_slowest_template"].is_a?(String)
        }
    ).to have_been_made
  end

  it "shortens view template paths" do
    simulate_request_with_collector do
      ActiveSupport::Notifications.instrument("render_template.action_view", {
        identifier: "/Users/deploy/app/views/orders/show.html.erb"
      }) { sleep 0.001 }
    end
    sleep 0.5

    expect(
      a_request(:post, "https://opentrace.test/api/logs")
        .with { |req|
          body = find_request_log(req)
          next false unless body

          rs = body["request_summary"]
          rs && rs["view_slowest_template"] == "orders/show.html.erb"
        }
    ).to have_been_made
  end

  it "includes cache operation summary from collector" do
    simulate_request_with_collector do
      ActiveSupport::Notifications.instrument("cache_read.active_support", {
        hit: true
      }) { sleep 0.001 }

      ActiveSupport::Notifications.instrument("cache_read.active_support", {
        hit: false
      }) { sleep 0.001 }

      ActiveSupport::Notifications.instrument("cache_write.active_support", {}) { sleep 0.001 }
    end
    sleep 0.5

    expect(
      a_request(:post, "https://opentrace.test/api/logs")
        .with { |req|
          body = find_request_log(req)
          next false unless body

          rs = body["request_summary"]
          rs &&
            rs["cache_reads"] == 2 &&
            rs["cache_hits"] == 1 &&
            rs["cache_writes"] == 1 &&
            rs["cache_hit_ratio"] == 0.5
        }
    ).to have_been_made
  end

  it "includes time_breakdown in request log" do
    simulate_request_with_collector do
      ActiveSupport::Notifications.instrument("sql.active_record", {
        name: "Query",
        sql: "SELECT 1",
        cached: false
      }) { sleep 0.001 }
    end
    sleep 0.5

    expect(
      a_request(:post, "https://opentrace.test/api/logs")
        .with { |req|
          body = find_request_log(req)
          next false unless body

          rs = body["request_summary"]
          next false unless rs

          tb = rs["time_breakdown"]
          tb.is_a?(Hash) &&
            tb.key?("sql_pct") &&
            tb.key?("view_pct") &&
            tb.key?("other_pct")
        }
    ).to have_been_made
  end

  it "includes timeline in request log" do
    simulate_request_with_collector do
      ActiveSupport::Notifications.instrument("sql.active_record", {
        name: "User Load",
        sql: "SELECT * FROM users",
        cached: false
      }) { sleep 0.001 }

      ActiveSupport::Notifications.instrument("render_template.action_view", {
        identifier: "/app/views/orders/show.html.erb"
      }) { sleep 0.001 }

      ActiveSupport::Notifications.instrument("cache_read.active_support", {
        hit: true
      }) { sleep 0.001 }
    end
    sleep 0.5

    expect(
      a_request(:post, "https://opentrace.test/api/logs")
        .with { |req|
          body = find_request_log(req)
          next false unless body

          rs = body["request_summary"]
          next false unless rs

          timeline = rs["timeline"]
          next false unless timeline.is_a?(Array) && timeline.size >= 3

          types = timeline.map { |e| e["t"] }
          types.include?("sql") && types.include?("view") && types.include?("cache")
        }
    ).to have_been_made
  end

  it "does not create collector when request_summary is disabled" do
    configure_opentrace!(request_summary: false)
    ActiveSupport::Notifications.reset!
    Rails.logger = ::Logger.new(StringIO.new)
    app = Rails::Application.new
    app.config.logger = ::Logger.new(StringIO.new)
    OpenTrace::Railtie.initializer_blocks.each { |block| block.call(app) }
    OpenTrace::Railtie.config.after_initialize_blocks.each { |block| block.call(app) }

    # Simulate middleware behavior — no collector should be created
    Fiber[:opentrace_sql_count] = 0
    Fiber[:opentrace_sql_total_ms] = 0.0
    expect(Fiber[:opentrace_collector]).to be_nil

    headers = Struct.new(:env).new({
      "action_dispatch.request_id" => "req-no-summary"
    })

    ActiveSupport::Notifications.instrument("sql.active_record", {
      name: "Load",
      sql: "SELECT 1",
      cached: false
    }) { sleep 0.001 }

    # Manually set Fiber-locals to simulate accumulated counts (middleware would track these)
    Fiber[:opentrace_sql_count] = 5
    Fiber[:opentrace_sql_total_ms] = 10.0

    ActiveSupport::Notifications.instrument("process_action.action_controller", {
      controller: "TestController",
      action: "index",
      method: "GET",
      path: "/test",
      status: 200,
      headers: headers
    }) {}
    sleep 0.5

    # Should still have sql_query_count from Fiber-local fallback
    expect(
      a_request(:post, "https://opentrace.test/api/logs")
        .with { |req|
          body = find_request_log(req)
          next false unless body

          body["metadata"]["sql_query_count"] == 5 &&
            !body["metadata"].key?("timeline")
        }
    ).to have_been_made
  ensure
    Fiber[:opentrace_sql_count] = nil
    Fiber[:opentrace_sql_total_ms] = nil
  end

  it "does not include view/cache data outside web requests" do
    # No collector set (simulating background job context)
    ActiveSupport::Notifications.instrument("render_template.action_view", {
      identifier: "/app/views/orders/show.html.erb"
    }) { sleep 0.001 }

    ActiveSupport::Notifications.instrument("cache_read.active_support", {
      hit: true
    }) { sleep 0.001 }

    # These events should be silently ignored (no collector)
    # Just verify no crash
    sleep 0.3

    # No request log with view data should be sent (neither in metadata nor request_summary)
    expect(
      a_request(:post, "https://opentrace.test/api/logs")
        .with { |req|
          body = find_request_log(req)
          next false unless body

          (body["metadata"]&.key?("view_render_count")) ||
            (body["request_summary"]&.key?("view_count"))
        }
    ).not_to have_been_made
  end
end
