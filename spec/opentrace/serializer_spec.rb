# frozen_string_literal: true

require "spec_helper"
require "opentrace/serializer"

RSpec.describe OpenTrace::Serializer do
  let(:document) do
    {
      "id" => "01J8XK2N4P6Q8R0S2T4V6W8X",
      "timestamp" => "2026-04-03T12:41:00.123456Z",
      "level" => "INFO",
      "service" => "test-app",
      "event" => {
        "type" => "http.request",
        "message" => "GET /api/users 200 42ms",
        "db" => {
          "queries" => [
            { "sql" => "SELECT * FROM users", "duration_ms" => 1.2, "binds" => [42] }
          ]
        }
      }
    }
  end

  describe ".estimate_size" do
    it "estimates string size" do
      expect(described_class.estimate_size("hello")).to eq(5)
    end

    it "estimates hash size" do
      size = described_class.estimate_size({ "key" => "value" })
      expect(size).to be > 0
    end

    it "estimates nested structure size" do
      size = described_class.estimate_size(document)
      expect(size).to be > 100
    end

    it "estimates numeric size" do
      expect(described_class.estimate_size(42)).to eq(8)
    end

    it "estimates nil/bool size" do
      expect(described_class.estimate_size(nil)).to eq(1)
      expect(described_class.estimate_size(true)).to eq(1)
    end
  end
end
