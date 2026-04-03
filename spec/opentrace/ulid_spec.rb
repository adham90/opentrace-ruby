# frozen_string_literal: true

require "spec_helper"
require "opentrace/ulid"

RSpec.describe OpenTrace::ULID do
  describe ".generate" do
    it "returns a 26-character string" do
      ulid = described_class.generate
      expect(ulid).to be_a(String)
      expect(ulid.length).to eq(26)
    end

    it "only contains valid Crockford Base32 characters" do
      valid_chars = /\A[0-9A-HJKMNP-TV-Z]+\z/
      20.times do
        ulid = described_class.generate
        expect(ulid).to match(valid_chars), "Expected '#{ulid}' to match Crockford Base32"
      end
    end

    it "produces different IDs on sequential calls" do
      a = described_class.generate
      b = described_class.generate
      expect(a).not_to eq(b)
    end

    it "IDs generated later sort lexicographically after earlier IDs" do
      first = described_class.generate
      sleep 0.002 # sleep 2ms to ensure timestamp advances
      second = described_class.generate
      expect(second).to be > first
    end

    it "is thread-safe: 100 concurrent generations produce 100 unique IDs" do
      results = Queue.new
      threads = 100.times.map do
        Thread.new { results << described_class.generate }
      end
      threads.each(&:join)

      ids = []
      ids << results.pop until results.empty?
      expect(ids.uniq.length).to eq(100)
    end
  end
end
