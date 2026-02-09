# frozen_string_literal: true

require "stringio"
require "securerandom"

# Load Rails stubs
require_relative "rails_spec_helper"

RSpec.describe "ActiveJob subscriber" do
  before do
    configure_opentrace!
    stub_request(:post, "https://opentrace.test/api/logs")
      .to_return(status: 201, body: '{"count":1}')
    ActiveSupport::Notifications.reset!

    # Initialize the Railtie (registers subscribers)
    Rails.logger = ::Logger.new(StringIO.new)
    app = Rails::Application.new
    app.config.logger = ::Logger.new(StringIO.new)
    OpenTrace::Railtie.initializer_blocks.each { |block| block.call(app) }
    OpenTrace::Railtie.config.after_initialize_blocks.each { |block| block.call(app) }
  end

  # Minimal job stub
  def make_job(attrs = {})
    job = Object.new
    job_class = attrs.fetch(:class_name, "OrderConfirmationJob")
    job.define_singleton_method(:class) { Struct.new(:name).new(job_class) }
    job.define_singleton_method(:job_id) { attrs.fetch(:job_id, "job-#{SecureRandom.hex(4)}") }
    job.define_singleton_method(:queue_name) { attrs.fetch(:queue_name, "default") }
    job.define_singleton_method(:executions) { attrs.fetch(:executions, 1) }
    job.define_singleton_method(:arguments) { attrs.fetch(:arguments, [42]) }
    job
  end

  it "captures successful job with expected fields" do
    job = make_job(class_name: "SendEmailJob", job_id: "job-abc", queue_name: "mailers")

    ActiveSupport::Notifications.instrument("perform.active_job", { job: job }) {}
    sleep 0.5

    expect(
      a_request(:post, "https://opentrace.test/api/logs")
        .with { |req|
          body = parse_log_body(req)
          body["level"] == "INFO" &&
            body["message"].include?("SendEmailJob") &&
            body["message"].include?("completed") &&
            body["metadata"]["job_class"] == "SendEmailJob" &&
            body["metadata"]["job_id"] == "job-abc" &&
            body["metadata"]["queue_name"] == "mailers" &&
            body["metadata"]["duration_ms"].is_a?(Numeric)
        }
    ).to have_been_made
  end

  it "captures failed job with exception details" do
    job = make_job(executions: 2)
    error = RuntimeError.new("SMTP server busy")
    error.set_backtrace([
      "app/jobs/order_confirmation_job.rb:12:in `perform'",
      "/gems/activejob/lib/active_job.rb:50:in `execute'"
    ])

    ActiveSupport::Notifications.instrument("perform.active_job", {
      job: job,
      exception_object: error
    }) {}
    sleep 0.5

    expect(
      a_request(:post, "https://opentrace.test/api/logs")
        .with { |req|
          body = parse_log_body(req)
          body["level"] == "ERROR" &&
            body["message"].include?("FAILED") &&
            body["message"].include?("attempt 2") &&
            body["metadata"]["exception_class"] == "RuntimeError" &&
            body["metadata"]["exception_message"] == "SMTP server busy" &&
            body["metadata"]["backtrace"].is_a?(Array)
        }
    ).to have_been_made
  end

  it "includes retry count in metadata" do
    job = make_job(executions: 3)

    ActiveSupport::Notifications.instrument("perform.active_job", { job: job }) {}
    sleep 0.5

    expect(
      a_request(:post, "https://opentrace.test/api/logs")
        .with { |req|
          parse_log_body(req)["metadata"]["executions"] == 3
        }
    ).to have_been_made
  end

  it "includes job arguments" do
    job = make_job(arguments: [42, "hello"])

    ActiveSupport::Notifications.instrument("perform.active_job", { job: job }) {}
    sleep 0.5

    expect(
      a_request(:post, "https://opentrace.test/api/logs")
        .with { |req|
          args = parse_log_body(req)["metadata"]["job_arguments"]
          args == [42, "hello"]
        }
    ).to have_been_made
  end

  it "truncates large arguments" do
    large_args = [{ data: "x" * 600 }]
    job = make_job(arguments: large_args)

    ActiveSupport::Notifications.instrument("perform.active_job", { job: job }) {}
    sleep 0.5

    expect(
      a_request(:post, "https://opentrace.test/api/logs")
        .with { |req|
          args = parse_log_body(req)["metadata"]["job_arguments"]
          args.is_a?(String) && args.length <= 516 && args.end_with?("...")
        }
    ).to have_been_made
  end

  it "cleans backtrace by filtering gem lines" do
    job = make_job
    error = RuntimeError.new("boom")
    error.set_backtrace([
      "app/jobs/order_confirmation_job.rb:12:in `perform'",
      "/gems/activejob/lib/active_job.rb:50:in `execute'",
      "app/services/mailer.rb:5:in `send'"
    ])

    ActiveSupport::Notifications.instrument("perform.active_job", {
      job: job,
      exception_object: error
    }) {}
    sleep 0.5

    expect(
      a_request(:post, "https://opentrace.test/api/logs")
        .with { |req|
          bt = parse_log_body(req)["metadata"]["backtrace"]
          bt.length == 2 && bt.none? { |l| l.include?("/gems/") }
        }
    ).to have_been_made
  end

  it "swallows errors without crashing" do
    expect {
      # Pass nil job — should be handled gracefully
      ActiveSupport::Notifications.instrument("perform.active_job", { job: nil }) {}
      sleep 0.3
    }.not_to raise_error
  end

  it "includes request_id from middleware when available" do
    OpenTrace.current_request_id = "req-job-test"
    job = make_job

    ActiveSupport::Notifications.instrument("perform.active_job", { job: job }) {}
    sleep 0.5

    expect(
      a_request(:post, "https://opentrace.test/api/logs")
        .with { |req|
          parse_log_body(req)["metadata"]["request_id"] == "req-job-test"
        }
    ).to have_been_made
  ensure
    OpenTrace.current_request_id = nil
  end
end
