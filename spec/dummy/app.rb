# frozen_string_literal: true

# Minimal dummy app for testing OpenTrace integration in a Rack/Rails-like environment.
# This simulates the critical parts of a Rails app to verify that OpenTrace
# does not impact request latency.

require "opentrace"

module Dummy
  # Simulates a Rails controller action that does typical work:
  # logging, SQL queries (simulated), and external HTTP calls (simulated)
  class App
    def call(env)
      # Simulate typical Rails request work
      simulate_sql_queries(env)
      simulate_logging
      simulate_view_render

      [200, { "Content-Type" => "text/plain" }, ["OK"]]
    end

    private

    def simulate_sql_queries(env)
      # Simulate 20 SQL queries (typical for a Rails index action)
      20.times do |i|
        # Just increment the counter like the SQL subscriber would
        if Fiber[:opentrace_sql_count]
          Fiber[:opentrace_sql_count] += 1
          Fiber[:opentrace_sql_total_ms] = (Fiber[:opentrace_sql_total_ms] || 0.0) + rand(0.5..5.0)
        end

        collector = Fiber[:opentrace_collector]
        collector&.record_sql(name: "User Load", duration_ms: rand(0.5..5.0), table: "users")
      end
    end

    def simulate_logging
      # Simulate 5 INFO log calls per request (typical Rails app)
      5.times { |i| OpenTrace.log("INFO", "Processing step #{i}") }
    end

    def simulate_view_render
      collector = Fiber[:opentrace_collector]
      return unless collector

      3.times do |i|
        collector.record_view(template: "app/views/users/show.html.erb", duration_ms: rand(1.0..10.0))
      end
    end
  end

  # Simulates an expensive context proc (like the Lena app has)
  class ExpensiveContextApp
    def call(env)
      10.times { |i| OpenTrace.log("INFO", "Step #{i}") }
      [200, {}, ["OK"]]
    end
  end
end
