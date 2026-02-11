# frozen_string_literal: true

RSpec.describe OpenTrace::Config do
  subject(:config) { described_class.new }

  describe "defaults" do
    it "has nil endpoint" do
      expect(config.endpoint).to be_nil
    end

    it "has nil api_key" do
      expect(config.api_key).to be_nil
    end

    it "has nil service" do
      expect(config.service).to be_nil
    end

    it "has nil environment" do
      expect(config.environment).to be_nil
    end

    it "has 1.0 second timeout" do
      expect(config.timeout).to eq(1.0)
    end

    it "is enabled by default" do
      expect(config.enabled).to be true
    end

    it "has empty ignore_paths" do
      expect(config.ignore_paths).to eq([])
    end
  end

  describe "#valid?" do
    it "returns false when all required fields are missing" do
      expect(config.valid?).to be false
    end

    it "returns false when only endpoint is set" do
      config.endpoint = "https://example.com"
      expect(config.valid?).to be false
    end

    it "returns false when only api_key is set" do
      config.api_key = "key"
      expect(config.valid?).to be false
    end

    it "returns false when only service is set" do
      config.service = "svc"
      expect(config.valid?).to be false
    end

    it "returns false when endpoint is empty string" do
      config.endpoint = ""
      config.api_key = "key"
      config.service = "svc"
      expect(config.valid?).to be false
    end

    it "returns false when api_key is empty string" do
      config.endpoint = "https://example.com"
      config.api_key = ""
      config.service = "svc"
      expect(config.valid?).to be false
    end

    it "returns false when service is empty string" do
      config.endpoint = "https://example.com"
      config.api_key = "key"
      config.service = ""
      expect(config.valid?).to be false
    end

    it "returns false when a required field is a non-string value" do
      config.endpoint = "https://example.com"
      config.api_key = 12345
      config.service = "svc"
      expect(config.valid?).to be false
    end

    it "returns true when all required fields are present" do
      config.endpoint = "https://example.com"
      config.api_key = "key"
      config.service = "svc"
      expect(config.valid?).to be true
    end

    it "does not require environment to be set" do
      config.endpoint = "https://example.com"
      config.api_key = "key"
      config.service = "svc"
      config.environment = nil
      expect(config.valid?).to be true
    end
  end

  describe "#enabled?" do
    it "returns false when disabled even with valid config" do
      config.endpoint = "https://example.com"
      config.api_key = "key"
      config.service = "svc"
      config.enabled = false
      expect(config.enabled?).to be false
    end

    it "returns false when enabled but config is invalid" do
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

  describe "mutability" do
    it "allows changing timeout" do
      config.timeout = 5.0
      expect(config.timeout).to eq(5.0)
    end

    it "allows changing environment" do
      config.environment = "staging"
      expect(config.environment).to eq("staging")
    end

    it "allows toggling enabled" do
      config.enabled = false
      expect(config.enabled).to be false
      config.enabled = true
      expect(config.enabled).to be true
    end
  end
end
