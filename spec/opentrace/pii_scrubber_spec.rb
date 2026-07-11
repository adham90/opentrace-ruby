# frozen_string_literal: true

RSpec.describe OpenTrace::PiiScrubber do
  describe ".scrub!" do
    it "redacts email addresses" do
      hash = { email: "alice@example.com", name: "Alice" }
      described_class.scrub!(hash)
      expect(hash[:email]).to eq("[REDACTED]")
      expect(hash[:name]).to eq("Alice")
    end

    it "redacts credit card numbers" do
      hash = { card: "4111 1111 1111 1111" }
      described_class.scrub!(hash)
      expect(hash[:card]).to eq("[REDACTED]")
    end

    it "redacts SSN patterns" do
      hash = { ssn_value: "123-45-6789" }
      described_class.scrub!(hash)
      expect(hash[:ssn_value]).to eq("[REDACTED]")
    end

    it "redacts bearer tokens" do
      hash = { auth: "Bearer eyJhbGciOiJIUzI1NiJ9.eyJ1c2VyX2lkIjoxfQ.abc123" }
      described_class.scrub!(hash)
      expect(hash[:auth]).to include("[REDACTED]")
    end

    it "redacts sensitive keys regardless of value" do
      hash = { password: "supersecret", api_key: "abc123", token: "xyz" }
      described_class.scrub!(hash)
      expect(hash[:password]).to eq("[REDACTED]")
      expect(hash[:api_key]).to eq("[REDACTED]")
      expect(hash[:token]).to eq("[REDACTED]")
    end

    it "handles nested hashes" do
      hash = { user: { email: "bob@test.com", name: "Bob" } }
      described_class.scrub!(hash)
      expect(hash[:user][:email]).to eq("[REDACTED]")
      expect(hash[:user][:name]).to eq("Bob")
    end

    it "handles arrays with strings" do
      hash = { emails: ["alice@test.com", "bob@test.com"] }
      described_class.scrub!(hash)
      expect(hash[:emails]).to eq(["[REDACTED]", "[REDACTED]"])
    end

    it "handles arrays with hashes" do
      hash = { users: [{ email: "alice@test.com" }] }
      described_class.scrub!(hash)
      expect(hash[:users][0][:email]).to eq("[REDACTED]")
    end

    it "matches sensitive keys by substring (finding #5)" do
      hash = {
        password_confirmation: "x",
        stripe_token: "tok_123",
        user_password: "y",
        author_id: 5 # contains 'auth' but is NOT sensitive
      }
      described_class.scrub!(hash)
      expect(hash[:password_confirmation]).to eq("[REDACTED]")
      expect(hash[:stripe_token]).to eq("[REDACTED]")
      expect(hash[:user_password]).to eq("[REDACTED]")
      expect(hash[:author_id]).to eq(5)
    end

    it "descends into arrays of arrays" do
      hash = { rows: [["alice@test.com", "ok"], ["bob@test.com"]] }
      described_class.scrub!(hash)
      expect(hash[:rows]).to eq([["[REDACTED]", "ok"], ["[REDACTED]"]])
    end

    it "does not redact 13-digit epoch-millisecond timestamps as credit cards" do
      hash = { logged_at_ms: "1707744000000" }
      described_class.scrub!(hash)
      expect(hash[:logged_at_ms]).to eq("1707744000000")
    end

    it "does not modify non-PII strings" do
      hash = { message: "User signed up", count: 42 }
      described_class.scrub!(hash)
      expect(hash[:message]).to eq("User signed up")
      expect(hash[:count]).to eq(42)
    end

    it "returns the hash even on error" do
      hash = { key: "value" }
      result = described_class.scrub!(hash)
      expect(result).to equal(hash)
    end

    it "handles nil input" do
      expect(described_class.scrub!(nil)).to be_nil
    end

    it "supports custom patterns" do
      custom = [/CUST-\d{8}/]
      hash = { customer: "CUST-12345678" }
      described_class.scrub!(hash, patterns: custom)
      expect(hash[:customer]).to eq("[REDACTED]")
    end
  end

  describe "SENSITIVE_KEYS" do
    it "includes common sensitive key names" do
      %w[password secret token api_key authorization].each do |key|
        expect(described_class::SENSITIVE_KEYS).to include(key)
      end
    end
  end

  describe "PATTERNS" do
    it "includes the expected pattern names" do
      expect(described_class::PATTERNS.keys).to include(
        :credit_card, :email, :ssn, :phone, :bearer_token, :api_key
      )
    end
  end
end
