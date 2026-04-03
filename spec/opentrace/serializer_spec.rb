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

  describe ".encode" do
    context "with msgpack format" do
      it "returns msgpack bytes and content type" do
        bytes, content_type = described_class.encode(document, format: :msgpack)
        expect(content_type).to eq("application/msgpack")
        expect(bytes).to be_a(String)
        expect(bytes.encoding).to eq(Encoding::ASCII_8BIT)
      end

      it "produces smaller output than JSON" do
        msgpack_bytes, = described_class.encode(document, format: :msgpack)
        json_bytes, = described_class.encode(document, format: :json)
        expect(msgpack_bytes.bytesize).to be < json_bytes.bytesize
      end

      it "roundtrips correctly" do
        bytes, content_type = described_class.encode(document, format: :msgpack)
        result = described_class.decode(bytes, content_type: content_type)
        expect(result).to eq(document)
      end
    end

    context "with json format" do
      it "returns JSON string and content type" do
        bytes, content_type = described_class.encode(document, format: :json)
        expect(content_type).to eq("application/json")
        expect(JSON.parse(bytes)).to eq(document)
      end

      it "roundtrips correctly" do
        bytes, content_type = described_class.encode(document, format: :json)
        result = described_class.decode(bytes, content_type: content_type)
        expect(result).to eq(document)
      end
    end

    context "with unknown format" do
      it "raises ArgumentError" do
        expect { described_class.encode(document, format: :xml) }.to raise_error(ArgumentError)
      end
    end

    context "msgpack fallback" do
      it "falls back to JSON if msgpack encoding fails" do
        # Objects that msgpack can't handle natively
        data = { "key" => "value" }
        allow(MessagePack).to receive(:pack).and_raise(StandardError.new("encode error"))
        bytes, content_type = described_class.encode(data, format: :msgpack)
        expect(content_type).to eq("application/json")
        expect(JSON.parse(bytes)).to eq(data)
      end
    end
  end

  describe ".decode" do
    it "decodes msgpack bytes" do
      bytes = MessagePack.pack(document)
      result = described_class.decode(bytes, content_type: "application/msgpack")
      expect(result).to eq(document)
    end

    it "decodes JSON bytes" do
      bytes = JSON.generate(document)
      result = described_class.decode(bytes, content_type: "application/json")
      expect(result).to eq(document)
    end

    it "defaults to JSON for unknown content type" do
      bytes = JSON.generate(document)
      result = described_class.decode(bytes, content_type: "text/plain")
      expect(result).to eq(document)
    end
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
