#!/usr/bin/env ruby
# frozen_string_literal: true

# Threaded usage example - demonstrates that OpenTrace is safe
# for concurrent use from multiple threads.
#
# Run:
#   ruby examples/threaded_usage.rb

require_relative "../lib/opentrace"

puts "=== OpenTrace Ruby Gem - Threaded Usage Example ==="
puts

endpoint = ENV.fetch("OPENTRACE_ENDPOINT", "http://localhost:8080")
api_key  = ENV.fetch("OPENTRACE_API_KEY", "")

OpenTrace.configure do |c|
  c.endpoint    = endpoint
  c.api_key     = api_key
  c.service     = "threaded-example"
  c.environment = "development"
end

puts "Enabled: #{OpenTrace.enabled?}"
puts "Spawning 5 threads, each sending 20 logs..."
puts

threads = 5.times.map do |t|
  Thread.new(t) do |thread_id|
    20.times do |i|
      OpenTrace.log("INFO", "Thread #{thread_id} - message #{i}", {
        thread_id: thread_id,
        sequence: i
      })
    end
    puts "  Thread #{thread_id} finished sending"
  end
end

threads.each(&:join)

puts
puts "All threads finished. Shutting down..."
OpenTrace.shutdown(timeout: 5)
puts "Done. 100 logs sent (or silently dropped if no server)."
