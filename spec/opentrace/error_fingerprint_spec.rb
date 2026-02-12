# frozen_string_literal: true

require_relative "../spec_helper"

RSpec.describe "Error fingerprinting" do
  before do
    configure_opentrace!
    stub_request(:post, "https://opentrace.test/api/logs")
      .to_return(status: 201, body: '{"count":1}')
  end

  it "includes error_fingerprint in OpenTrace.error" do
    error = RuntimeError.new("something broke")
    error.set_backtrace([
      "app/controllers/orders_controller.rb:18:in `show'",
      "/gems/activesupport/lib/support.rb:50:in `call'"
    ])

    OpenTrace.error(error)
    sleep 0.5

    expect(
      a_request(:post, "https://opentrace.test/api/logs")
        .with { |req|
          body = parse_log_body(req)
          fp = body["metadata"]["error_fingerprint"]
          fp.is_a?(String) && fp.length == 12
        }
    ).to have_been_made
  end

  it "produces same fingerprint for same error at same location" do
    fingerprints = 2.times.map do
      error = RuntimeError.new("different message each time #{rand}")
      error.set_backtrace(["app/controllers/orders_controller.rb:18:in `show'"])

      # Compute directly
      OpenTrace.send(:compute_error_fingerprint, "RuntimeError",
        error.backtrace.reject { |l| l.include?("/gems/") })
    end

    expect(fingerprints[0]).to eq(fingerprints[1])
  end

  it "produces different fingerprints for different errors" do
    fp1 = OpenTrace.send(:compute_error_fingerprint, "RuntimeError",
      ["app/controllers/orders_controller.rb:18:in `show'"])
    fp2 = OpenTrace.send(:compute_error_fingerprint, "ActiveRecord::RecordNotFound",
      ["app/controllers/orders_controller.rb:18:in `show'"])

    expect(fp1).not_to eq(fp2)
  end

  it "produces different fingerprints for different locations" do
    fp1 = OpenTrace.send(:compute_error_fingerprint, "RuntimeError",
      ["app/controllers/orders_controller.rb:18:in `show'"])
    fp2 = OpenTrace.send(:compute_error_fingerprint, "RuntimeError",
      ["app/controllers/users_controller.rb:10:in `index'"])

    expect(fp1).not_to eq(fp2)
  end

  it "is stable across line number changes" do
    fp1 = OpenTrace.send(:compute_error_fingerprint, "RuntimeError",
      ["app/controllers/orders_controller.rb:18:in `show'"])
    fp2 = OpenTrace.send(:compute_error_fingerprint, "RuntimeError",
      ["app/controllers/orders_controller.rb:99:in `show'"])

    expect(fp1).to eq(fp2)
  end

  it "handles nil backtrace without crash" do
    error = RuntimeError.new("no backtrace")
    # No set_backtrace — backtrace is nil

    expect { OpenTrace.error(error) }.not_to raise_error
  end

  it "handles empty backtrace" do
    fp = OpenTrace.send(:compute_error_fingerprint, "RuntimeError", [])
    expect(fp).to be_nil.or(be_a(String))
  end
end
