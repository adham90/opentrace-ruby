# frozen_string_literal: true

RSpec.describe OpenTrace::Sampler do
  let(:config) do
    OpenTrace::Config.new.tap do |c|
      c.sample_rate = 1.0
      c.sampler = nil
    end
  end
  subject(:sampler) { described_class.new(config) }

  describe "#sample?" do
    it "always samples when rate is 1.0" do
      100.times { expect(sampler.sample?).to be true }
    end

    it "never samples when rate is 0.0" do
      config.sample_rate = 0.0
      100.times { expect(sampler.sample?).to be false }
    end

    it "samples approximately at the configured rate" do
      config.sample_rate = 0.5
      results = 10_000.times.map { sampler.sample? }
      sampled = results.count(true)
      # Allow generous tolerance for randomness
      expect(sampled).to be_between(4000, 6000)
    end
  end

  describe "#effective_rate" do
    it "returns sample_rate with zero backpressure" do
      config.sample_rate = 0.5
      expect(sampler.effective_rate).to eq(0.5)
    end

    it "uses custom sampler proc when provided" do
      config.sampler = ->(_env) { 0.1 }
      expect(sampler.effective_rate).to eq(0.1)
    end

    it "falls back to sample_rate if sampler proc raises" do
      config.sample_rate = 0.5
      config.sampler = ->(_env) { raise "broken" }
      expect(sampler.effective_rate).to eq(0.5)
    end

    it "passes env to sampler proc" do
      received_env = nil
      config.sampler = ->(env) { received_env = env; 0.5 }
      sampler.effective_rate("test_env")
      expect(received_env).to eq("test_env")
    end
  end

  describe "backpressure" do
    it "starts at zero" do
      expect(sampler.backpressure_level).to eq(0)
    end

    it "increases backpressure" do
      sampler.increase_backpressure!
      expect(sampler.backpressure_level).to eq(1)
    end

    it "decreases backpressure" do
      3.times { sampler.increase_backpressure! }
      sampler.decrease_backpressure!
      expect(sampler.backpressure_level).to eq(2)
    end

    it "does not go below zero" do
      sampler.decrease_backpressure!
      expect(sampler.backpressure_level).to eq(0)
    end

    it "caps at MAX_BACKPRESSURE" do
      15.times { sampler.increase_backpressure! }
      expect(sampler.backpressure_level).to eq(OpenTrace::Sampler::MAX_BACKPRESSURE)
    end

    it "reduces effective rate by 2^n" do
      config.sample_rate = 1.0

      sampler.increase_backpressure! # level 1 → rate = 1.0/2 = 0.5
      expect(sampler.effective_rate).to eq(0.5)

      sampler.increase_backpressure! # level 2 → rate = 1.0/4 = 0.25
      expect(sampler.effective_rate).to eq(0.25)

      sampler.increase_backpressure! # level 3 → rate = 1.0/8 = 0.125
      expect(sampler.effective_rate).to eq(0.125)
    end
  end

  describe "unsampled requests skip Fiber-local setup" do
    before do
      configure_opentrace!(sample_rate: 0.0)
    end

    it "does not set Fiber-locals for unsampled requests" do
      captured_sql_count = :not_checked
      middleware = OpenTrace::Middleware.new(->(env) {
        captured_sql_count = Fiber[:opentrace_sql_count]
        [200, {}, ["OK"]]
      })

      middleware.call("action_dispatch.request_id" => "unsampled-test")

      expect(captured_sql_count).to be_nil
    end
  end
end
