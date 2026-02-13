# frozen_string_literal: true

RSpec.describe OpenTrace::LocalVars do
  describe ".capture" do
    it "captures local variables from a binding" do
      user_name = "Alice"
      user_id = 42
      result = described_class.capture(binding)

      expect(result).to be_an(Array)
      names = result.map { |v| v[:name] }
      expect(names).to include("user_name", "user_id")

      alice_var = result.find { |v| v[:name] == "user_name" }
      expect(alice_var[:value]).to include("Alice")
      expect(alice_var[:type]).to eq("String")
    end

    it "skips internal variables starting with _" do
      _internal = "hidden"
      visible = "shown"
      result = described_class.capture(binding)

      names = result.map { |v| v[:name] }
      expect(names).not_to include("_internal")
      expect(names).to include("visible")
    end

    it "limits to MAX_VARS variables" do
      # Create more than 10 local variables
      a1 = 1; a2 = 2; a3 = 3; a4 = 4; a5 = 5
      a6 = 6; a7 = 7; a8 = 8; a9 = 9; a10 = 10
      a11 = 11
      # Use them to avoid warnings
      [a1, a2, a3, a4, a5, a6, a7, a8, a9, a10, a11]
      result = described_class.capture(binding)

      expect(result.length).to be <= OpenTrace::LocalVars::MAX_VARS
    end

    it "truncates long values" do
      long_string = "x" * 1000
      result = described_class.capture(binding)

      long_var = result.find { |v| v[:name] == "long_string" }
      expect(long_var[:value].length).to be <= OpenTrace::LocalVars::MAX_VALUE_LENGTH + 3 # +3 for "..."
    end

    it "returns nil for non-Binding input" do
      expect(described_class.capture("not a binding")).to be_nil
      expect(described_class.capture(nil)).to be_nil
    end

    it "handles uninspectable objects" do
      obj = Object.new
      def obj.inspect; raise "boom"; end

      result = described_class.capture(binding)
      obj_var = result.find { |v| v[:name] == "obj" }
      expect(obj_var[:value]).to eq("#<uninspectable>")
    end
  end
end

RSpec.describe "OpenTrace.capture_binding" do
  before do
    OpenTrace.reset!
    OpenTrace.configure do |c|
      c.endpoint = "https://opentrace.test"
      c.api_key = "test-key"
      c.service = "test-app"
      c.flush_interval = 0.2
      c.local_vars_capture = true
    end
    stub_request(:any, /opentrace\.test/).to_return(status: 200, body: "{}")
  end

  after { OpenTrace.shutdown(timeout: 1) }

  it "attaches local variables to exception" do
    begin
      user_name = "Bob"
      raise "test error"
    rescue => e
      OpenTrace.capture_binding(e, binding)
      expect(e.instance_variable_get(:@__opentrace_local_vars__)).to be_an(Array)
      vars = e.instance_variable_get(:@__opentrace_local_vars__)
      names = vars.map { |v| v[:name] }
      expect(names).to include("user_name")
    end
  end

  it "does nothing when local_vars_capture is false" do
    OpenTrace.config.local_vars_capture = false
    begin
      raise "test error"
    rescue => e
      OpenTrace.capture_binding(e, binding)
      expect(e.instance_variable_defined?(:@__opentrace_local_vars__)).to be false
    end
  end

  it "integrates with error method" do
    enqueued = []
    allow_any_instance_of(OpenTrace::Client).to receive(:enqueue) { |_, p| enqueued << p }

    begin
      user = "Alice"
      raise "boom"
    rescue => e
      OpenTrace.capture_binding(e, binding)
      OpenTrace.error(e)
    end

    expect(enqueued.size).to eq(1)
    metadata = enqueued[0][3] # metadata is slot 3
    expect(metadata[:local_variables]).to be_an(Array)
  end

  it "does not raise if capture_binding fails" do
    expect {
      OpenTrace.capture_binding(nil, nil)
    }.not_to raise_error
  end
end
