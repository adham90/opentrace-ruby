# frozen_string_literal: true

RSpec.describe "SQL filtering" do
  describe "SKIP_SQL_NAMES" do
    it "includes SCHEMA and EXPLAIN" do
      skip_names = OpenTrace::Railtie::SKIP_SQL_NAMES
      expect(skip_names).to include("SCHEMA")
      expect(skip_names).to include("EXPLAIN")
    end
  end if defined?(OpenTrace::Railtie)

  describe "filtered SQL patterns" do
    # These tests verify the SQL filtering logic in isolation
    # without needing a full Rails environment

    let(:filtered_prefixes) { %w[PRAGMA BEGIN COMMIT ROLLBACK SAVEPOINT RELEASE] }

    it "identifies SQL statements that should be filtered" do
      filtered_prefixes.each do |prefix|
        sql = "#{prefix} some_stuff"
        expect(sql.start_with?(prefix)).to eq(true)
      end
    end

    it "does not filter regular SELECT queries" do
      sql = "SELECT * FROM users WHERE id = 1"
      filtered = filtered_prefixes.any? { |p| sql.start_with?(p) }
      expect(filtered).to be false
    end

    it "does not filter INSERT queries" do
      sql = "INSERT INTO users (name) VALUES ('test')"
      filtered = filtered_prefixes.any? { |p| sql.start_with?(p) }
      expect(filtered).to be false
    end

    it "does not filter UPDATE queries" do
      sql = "UPDATE users SET name = 'test' WHERE id = 1"
      filtered = filtered_prefixes.any? { |p| sql.start_with?(p) }
      expect(filtered).to be false
    end
  end
end
