# frozen_string_literal: true

module OpenTrace
  module PiiScrubber
    REDACTED = "[REDACTED]"

    PATTERNS = {
      credit_card: /\b(?:\d[ -]*?){13,16}\b/,
      email: /\b[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}\b/,
      ssn: /\b\d{3}-\d{2}-\d{4}\b/,
      phone: /\b(?:\+?1[-.\s]?)?\(?\d{3}\)?[-.\s]?\d{3}[-.\s]?\d{4}\b/,
      bearer_token: /Bearer\s+[A-Za-z0-9\-._~+\/]+=*/,
      api_key: /\b(?:sk|pk|api[_-]?key)[_-][A-Za-z0-9]{20,}\b/i
    }.freeze

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
        key_s = key.to_s.downcase
        if SENSITIVE_KEYS.include?(key_s)
          hash[key] = REDACTED
        elsif value.is_a?(String)
          hash[key] = scrub_string(value, active_patterns)
        elsif value.is_a?(Hash)
          scrub!(value, patterns: active_patterns)
        elsif value.is_a?(Array)
          value.each_with_index do |v, i|
            if v.is_a?(String)
              value[i] = scrub_string(v, active_patterns)
            elsif v.is_a?(Hash)
              scrub!(v, patterns: active_patterns)
            end
          end
        end
      end

      hash
    rescue StandardError
      hash
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
