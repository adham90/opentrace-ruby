# frozen_string_literal: true

require "set"

module OpenTrace
  module PiiScrubber
    REDACTED = "[REDACTED]"

    PATTERNS = {
      # 15-16 digit runs (optionally space/dash separated). The old {13,16}
      # bound matched bare 13-digit epoch-millisecond timestamps; require 15+.
      credit_card: /\b(?:\d[ -]?){15,16}\b/,
      email: /\b[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}\b/,
      ssn: /\b\d{3}-\d{2}-\d{4}\b/,
      phone: /\b(?:\+?1[-.\s]?)?\(?\d{3}\)?[-.\s]?\d{3}[-.\s]?\d{4}\b/,
      bearer_token: /Bearer\s+[A-Za-z0-9\-._~+\/]+=*/,
      api_key: /\b(?:sk|pk|api[_-]?key)[_-][A-Za-z0-9]{20,}\b/i
    }.freeze

    # Matched by SUBSTRING (not exact key) so variants like
    # password_confirmation, stripe_token and user_password are also redacted.
    SENSITIVE_KEYS = Set.new(%w[
      password passwd secret token api_key apikey
      authorization auth_token access_token refresh_token
      credit_card card_number cvv ssn
    ]).freeze

    module_function

    # Scrub PII from a payload hash (in-place mutation for performance).
    def scrub!(hash, patterns: nil)
      return hash unless hash.is_a?(Hash)

      active_patterns = patterns || PATTERNS.values

      hash.each do |key, value|
        if sensitive_key?(key.to_s.downcase)
          hash[key] = REDACTED
        else
          hash[key] = scrub_value(value, active_patterns)
        end
      end

      hash
    rescue StandardError
      hash
    end

    # Recursively scrub any value — strings, nested hashes, and arrays
    # (including arrays-of-arrays).
    def scrub_value(value, patterns)
      case value
      when String then scrub_string(value, patterns)
      when Hash   then scrub!(value, patterns: patterns)
      when Array  then value.map! { |v| scrub_value(v, patterns) }
      else value
      end
    rescue StandardError
      value
    end

    def sensitive_key?(key_s)
      SENSITIVE_KEYS.any? { |sk| key_s.include?(sk) }
    end

    def scrub_string(str, patterns)
      result = str
      patterns.each do |pattern|
        result = result.gsub(pattern, REDACTED)
      end
      result
    rescue StandardError
      str
    end
  end
end
