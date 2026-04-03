# frozen_string_literal: true

RSpec.describe "Context/metadata payload integration" do
  before { stub_request(:post, "https://opentrace.test/api/logs").to_return(status: 201, body: '{"count":1}') }

  it "includes context fields in the document" do
    configure_opentrace!(context: -> { { user_id: 42, tenant: "acme" } })
    OpenTrace.log("INFO", "user action")
    OpenTrace.shutdown(timeout: 5)
    expect(a_request(:post, "https://opentrace.test/api/logs").with { |req|
      body = parse_log_body(req)
      ctx = body["context"]
      ctx.is_a?(Hash) && ctx["user_id"] == 42 && ctx["tenant"] == "acme"
    }).to have_been_made.once
  end

  it "merges caller metadata" do
    configure_opentrace!(context: -> { { user_id: 42 } })
    OpenTrace.log("WARN", "merged test", { extra_key: "extra_val", custom: true })
    OpenTrace.shutdown(timeout: 5)
    expect(a_request(:post, "https://opentrace.test/api/logs").with { |req|
      body = parse_log_body(req)
      body["metadata"]["extra_key"] == "extra_val" && body["metadata"]["custom"] == true
    }).to have_been_made.once
  end

  it "caller metadata overrides context on collision" do
    configure_opentrace!(context: -> { { user_id: 1, source: "ctx" } })
    OpenTrace.log("INFO", "override test", { user_id: 99, source: "caller" })
    OpenTrace.shutdown(timeout: 5)
    expect(a_request(:post, "https://opentrace.test/api/logs").with { |req|
      meta = parse_log_body(req)["metadata"]
      meta["user_id"] == 99 && meta["source"] == "caller"
    }).to have_been_made.once
  end

  it "works with static context (no context proc)" do
    configure_opentrace!
    OpenTrace.log("INFO", "no context proc")
    OpenTrace.shutdown(timeout: 5)
    expect(a_request(:post, "https://opentrace.test/api/logs").with { |req|
      body = parse_log_body(req)
      ctx = body["context"]
      body["message"] == "no context proc" && ctx.is_a?(Hash) && ctx.key?("hostname")
    }).to have_been_made.once
  end

  it "context resolution works for buffer-based system" do
    configure_opentrace!(context: -> { { user_id: 55, org: "widgets" } })
    ctx = OpenTrace.send(:resolve_context_raw)
    ctx = ctx.is_a?(Hash) ? ctx : {}
    expect(ctx[:user_id]).to eq(55)
    expect(ctx[:org]).to eq("widgets")
  end
end
