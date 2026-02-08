# frozen_string_literal: true

RSpec.describe OpenTrace::Config do
  subject(:config) { described_class.new }

  describe "defaults" do
    it "has nil endpoint" do
      expect(config.endpoint).to be_nil
    end

    it "has 1.0 second timeout" do
      expect(config.timeout).to eq(1.0)
    end

    it "is enabled by default" do
      expect(config.enabled).to be true
    end
  end

  describe "#valid?" do
    it "returns false when required fields are missing" do
      expect(config.valid?).to be false
    end

    it "returns false when endpoint is empty" do
      config.endpoint = ""
      config.api_key = "key"
      config.service = "svc"
      expect(config.valid?).to be false
    end

    it "returns true when all required fields are present" do
      config.endpoint = "https://example.com"
      config.api_key = "key"
      config.service = "svc"
      expect(config.valid?).to be true
    end
  end

  describe "#enabled?" do
    it "returns false when disabled" do
      config.endpoint = "https://example.com"
      config.api_key = "key"
      config.service = "svc"
      config.enabled = false
      expect(config.enabled?).to be false
    end

    it "returns false when config is invalid" do
      config.enabled = true
      expect(config.enabled?).to be false
    end

    it "returns true when enabled and valid" do
      config.endpoint = "https://example.com"
      config.api_key = "key"
      config.service = "svc"
      config.enabled = true
      expect(config.enabled?).to be true
    end
  end
end
