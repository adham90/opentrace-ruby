#!/usr/bin/env ruby
# frozen_string_literal: true

# Basic usage example for the OpenTrace Ruby gem.
#
# Run:
#   ruby examples/basic_usage.rb
#
# Set OPENTRACE_ENDPOINT and OPENTRACE_API_KEY environment variables
# to point at your OpenTrace server, or it will use defaults and
# auto-disable (demonstrating the safety behavior).

require_relative "../lib/opentrace"

puts "=== OpenTrace Ruby Gem - Basic Usage Example ==="
puts

# --- Configuration ---

endpoint = ENV.fetch("OPENTRACE_ENDPOINT", "http://localhost:8080")
api_key  = ENV.fetch("OPENTRACE_API_KEY", "")

if api_key.empty?
  puts "No OPENTRACE_API_KEY set. The gem will auto-disable."
  puts "Set OPENTRACE_ENDPOINT and OPENTRACE_API_KEY to test against a real server."
  puts
end

OpenTrace.configure do |c|
  c.endpoint    = endpoint
  c.api_key     = api_key
  c.service     = "example-app"
  c.environment = "development"
  c.timeout     = 2.0
end

puts "Configured: endpoint=#{endpoint} service=example-app"
puts "Enabled: #{OpenTrace.enabled?}"
puts

# --- Direct logging ---

puts "Sending direct logs..."

OpenTrace.log("INFO", "Application started", {
  version: "1.0.0",
  pid: Process.pid
})

OpenTrace.log("WARN", "Cache miss for user lookup", {
  user_id: 42,
  cache_key: "user:42"
})

OpenTrace.log("ERROR", "Payment processing failed", {
  trace_id: "trace-abc-123",
  user_id: 99,
  exception: {
    class: "Stripe::CardError",
    message: "Your card was declined",
    backtrace: ["app/services/payment.rb:42", "app/controllers/orders_controller.rb:18"]
  }
})

puts "  Sent 3 direct logs"
puts

# --- Logger wrapper ---

puts "Using Logger wrapper..."

require "logger"
stdout_logger = Logger.new($stdout)
logger = OpenTrace::Logger.new(stdout_logger, metadata: { component: "example" })

logger.info("This message goes to STDOUT and to OpenTrace")
logger.debug("Debug messages are forwarded too")
logger.error("Errors are forwarded with level ERROR")

puts
puts "  Logger wrapper forwarded 3 messages"
puts

# --- Disable / Enable ---

puts "Testing disable/enable..."

OpenTrace.disable!
puts "  Disabled: #{OpenTrace.enabled?}"

OpenTrace.log("INFO", "This log is silently dropped")
puts "  Logged while disabled (silently dropped)"

OpenTrace.enable!
puts "  Re-enabled: #{OpenTrace.enabled?}"
puts

# --- Graceful shutdown ---

puts "Shutting down (draining queue)..."
OpenTrace.shutdown(timeout: 5)
puts "  Done."
puts
puts "=== Example complete ==="
