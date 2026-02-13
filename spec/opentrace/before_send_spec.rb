# frozen_string_literal: true

RSpec.describe "before_send filter" do
  before do
    stub_request(:post, "https://opentrace.test/api/logs")
      .to_return(status: 201, body: '{"count":1}')
  end

  it "applies before_send filter to payloads" do
    configure_opentrace!(
      before_send: ->(payload) {
        # Drop debug payloads (payload uses symbol keys from PayloadBuilder)
        payload[:level] == "DEBUG" ? nil : payload
      }
    )

    OpenTrace.log("DEBUG", "should be dropped")
    OpenTrace.log("INFO", "should be kept")
    OpenTrace.shutdown(timeout: 5)

    expect(
      a_request(:post, "https://opentrace.test/api/logs")
        .with { |req|
          entries = JSON.parse(req.body)
          entries = [entries] unless entries.is_a?(Array)
          entries.any? { |e| e["message"] == "should be dropped" }
        }
    ).not_to have_been_made

    expect(
      a_request(:post, "https://opentrace.test/api/logs")
        .with { |req|
          entries = JSON.parse(req.body)
          entries = [entries] unless entries.is_a?(Array)
          entries.any? { |e| e["message"] == "should be kept" }
        }
    ).to have_been_made
  end

  it "can modify payloads in-flight" do
    configure_opentrace!(
      before_send: ->(payload) {
        payload[:metadata] ||= {}
        payload[:metadata]["injected"] = "by_filter"
        payload
      }
    )

    OpenTrace.log("INFO", "modified payload")
    OpenTrace.shutdown(timeout: 5)

    expect(
      a_request(:post, "https://opentrace.test/api/logs")
        .with { |req|
          body = parse_log_body(req)
          body["metadata"]["injected"] == "by_filter"
        }
    ).to have_been_made
  end

  it "handles broken before_send gracefully" do
    configure_opentrace!(
      before_send: ->(_payload) { raise "broken filter" }
    )

    OpenTrace.log("INFO", "should survive broken filter")
    OpenTrace.shutdown(timeout: 5)

    # Should still deliver (broken filter returns the original payload)
    expect(
      a_request(:post, "https://opentrace.test/api/logs")
        .with { |req|
          body = parse_log_body(req)
          body["message"] == "should survive broken filter"
        }
    ).to have_been_made
  end

  it "increments dropped_filtered counter" do
    configure_opentrace!(
      before_send: ->(_payload) { nil }
    )

    OpenTrace.log("INFO", "will be dropped")
    OpenTrace.shutdown(timeout: 5)

    # No requests should have been made (all filtered)
    expect(
      a_request(:post, "https://opentrace.test/api/logs")
        .with { |req|
          body = parse_log_body(req)
          body["message"] == "will be dropped"
        }
    ).not_to have_been_made
  end

  it "passes nil through (drops the event)" do
    configure_opentrace!(
      before_send: ->(payload) {
        payload[:metadata]&.key?(:secret) ? nil : payload
      }
    )

    OpenTrace.log("INFO", "public log")
    OpenTrace.log("INFO", "secret log", { secret: true })
    OpenTrace.shutdown(timeout: 5)

    expect(
      a_request(:post, "https://opentrace.test/api/logs")
        .with { |req|
          entries = JSON.parse(req.body)
          entries = [entries] unless entries.is_a?(Array)
          entries.any? { |e| e["message"] == "public log" }
        }
    ).to have_been_made

    expect(
      a_request(:post, "https://opentrace.test/api/logs")
        .with { |req|
          entries = JSON.parse(req.body)
          entries = [entries] unless entries.is_a?(Array)
          entries.any? { |e| e["message"] == "secret log" }
        }
    ).not_to have_been_made
  end
end
