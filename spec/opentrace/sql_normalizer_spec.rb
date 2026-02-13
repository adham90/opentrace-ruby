# frozen_string_literal: true

RSpec.describe OpenTrace::SqlNormalizer do
  describe ".normalize" do
    it "replaces integer literals" do
      sql = "SELECT * FROM users WHERE id = 42"
      expect(described_class.normalize(sql)).to eq("SELECT * FROM users WHERE id = ?")
    end

    it "replaces float literals" do
      sql = "SELECT * FROM products WHERE price > 19.99"
      expect(described_class.normalize(sql)).to eq("SELECT * FROM products WHERE price > ?")
    end

    it "replaces single-quoted strings" do
      sql = "SELECT * FROM users WHERE email = 'alice@example.com'"
      expect(described_class.normalize(sql)).to eq("SELECT * FROM users WHERE email = ?")
    end

    it "replaces double-quoted strings" do
      sql = 'SELECT * FROM users WHERE name = "Alice"'
      expect(described_class.normalize(sql)).to eq("SELECT * FROM users WHERE name = ?")
    end

    it "replaces multiple literals in one query" do
      sql = "SELECT * FROM users WHERE id = 42 AND name = 'Alice' AND active = TRUE"
      expect(described_class.normalize(sql)).to eq("SELECT * FROM users WHERE id = ? AND name = ? AND active = ?")
    end

    it "replaces NULL" do
      sql = "SELECT * FROM users WHERE deleted_at IS NULL"
      expect(described_class.normalize(sql)).to eq("SELECT * FROM users WHERE deleted_at IS ?")
    end

    it "replaces boolean TRUE and FALSE" do
      sql = "SELECT * FROM users WHERE active = TRUE AND banned = false"
      expect(described_class.normalize(sql)).to eq("SELECT * FROM users WHERE active = ? AND banned = ?")
    end

    it "replaces hex literals" do
      sql = "SELECT * FROM data WHERE hash = 0xDEADBEEF"
      expect(described_class.normalize(sql)).to eq("SELECT * FROM data WHERE hash = ?")
    end

    it "handles INSERT with multiple values" do
      sql = "INSERT INTO logs (msg, level) VALUES ('hello', 1), ('world', 2)"
      expect(described_class.normalize(sql)).to eq("INSERT INTO logs (msg, level) VALUES (?, ?), (?, ?)")
    end

    it "handles escaped quotes in strings" do
      sql = "SELECT * FROM users WHERE name = 'O\\'Brien'"
      expect(described_class.normalize(sql)).to eq("SELECT * FROM users WHERE name = ?")
    end

    it "handles IN lists" do
      sql = "SELECT * FROM users WHERE id IN (1, 2, 3, 4, 5)"
      expect(described_class.normalize(sql)).to eq("SELECT * FROM users WHERE id IN (?, ?, ?, ?, ?)")
    end

    it "preserves table and column names" do
      sql = "SELECT id, name, email FROM users WHERE active = TRUE"
      result = described_class.normalize(sql)
      expect(result).to include("SELECT")
      expect(result).to include("users")
      expect(result).to include("id, name, email")
    end

    it "returns the original string for nil input" do
      expect(described_class.normalize(nil)).to be_nil
    end

    it "returns the original string for empty input" do
      expect(described_class.normalize("")).to eq("")
    end

    it "handles UPDATE queries" do
      sql = "UPDATE users SET name = 'Bob', age = 30 WHERE id = 1"
      expect(described_class.normalize(sql)).to eq("UPDATE users SET name = ?, age = ? WHERE id = ?")
    end

    it "handles LIMIT and OFFSET" do
      sql = "SELECT * FROM users LIMIT 25 OFFSET 50"
      expect(described_class.normalize(sql)).to eq("SELECT * FROM users LIMIT ? OFFSET ?")
    end
  end

  describe ".fingerprint" do
    it "returns a 12-character hex string" do
      fp = described_class.fingerprint("SELECT * FROM users WHERE id = 42")
      expect(fp).to match(/\A[0-9a-f]{12}\z/)
    end

    it "returns same fingerprint for same query with different params" do
      fp1 = described_class.fingerprint("SELECT * FROM users WHERE id = 42")
      fp2 = described_class.fingerprint("SELECT * FROM users WHERE id = 99")
      expect(fp1).to eq(fp2)
    end

    it "returns different fingerprint for different queries" do
      fp1 = described_class.fingerprint("SELECT * FROM users WHERE id = 42")
      fp2 = described_class.fingerprint("SELECT * FROM orders WHERE id = 42")
      expect(fp1).not_to eq(fp2)
    end

    it "returns same fingerprint regardless of string values" do
      fp1 = described_class.fingerprint("SELECT * FROM users WHERE email = 'alice@test.com'")
      fp2 = described_class.fingerprint("SELECT * FROM users WHERE email = 'bob@test.com'")
      expect(fp1).to eq(fp2)
    end
  end
end
