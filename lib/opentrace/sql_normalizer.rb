# frozen_string_literal: true

require "digest"

module OpenTrace
  module SqlNormalizer
    module_function

    # Replace literal values with ? placeholders for grouping.
    # Handles: integers, floats, single-quoted strings, double-quoted strings,
    # hex literals, boolean literals, NULL.
    #
    #   normalize("SELECT * FROM users WHERE id = 42 AND name = 'Alice'")
    #   # => "SELECT * FROM users WHERE id = ? AND name = ?"
    #
    def normalize(sql)
      return sql if sql.nil? || sql.empty?

      sql.gsub(LITERAL_PATTERN, "?")
    end

    # Compute a fingerprint for a normalized query.
    # Two queries with the same fingerprint are "the same query with different params."
    def fingerprint(sql)
      normalized = normalize(sql)
      Digest::MD5.hexdigest(normalized)[0, 12]
    end

    # Order matters: strings first (to avoid matching numbers inside strings),
    # then numbers, then special literals.
    LITERAL_PATTERN = Regexp.union(
      /'(?:[^'\\]|\\.)*'/,           # single-quoted strings
      /"(?:[^"\\]|\\.)*"/,           # double-quoted strings (MySQL)
      /\b0x[0-9a-fA-F]+\b/,         # hex literals
      /\b\d+\.\d+\b/,               # floats
      /\b\d+\b/,                     # integers
      /\bTRUE\b/i,                   # boolean TRUE
      /\bFALSE\b/i,                  # boolean FALSE
      /\bNULL\b/i                    # NULL
    ).freeze

    private_constant :LITERAL_PATTERN
  end
end
