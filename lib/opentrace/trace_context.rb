# frozen_string_literal: true

require "securerandom"

module OpenTrace
  module TraceContext
    TRACEPARENT_REGEX = /\A(\h{2})-(\h{32})-(\h{16})-(\h{2})\z/

    # Parse a W3C traceparent header.
    # Returns a Hash with :version, :trace_id, :parent_id, :flags or nil if invalid.
    def self.parse_traceparent(header)
      return nil unless header

      match = TRACEPARENT_REGEX.match(header.strip)
      return nil unless match

      {
        version: match[1],
        trace_id: match[2],
        parent_id: match[3],
        flags: match[4]
      }
    end

    # Build a W3C traceparent header string.
    def self.build_traceparent(trace_id:, span_id:, sampled: true)
      normalized = normalize_trace_id(trace_id)
      flags = sampled ? "01" : "00"
      "00-#{normalized}-#{span_id}-#{flags}"
    end

    # Normalize any trace ID to 32 lowercase hex characters.
    # Handles UUIDs (strip hyphens), short IDs (pad), and long IDs (truncate).
    def self.normalize_trace_id(id)
      hex = id.to_s.delete("-").downcase.gsub(/[^0-9a-f]/, "")
      return nil if hex.empty?

      if hex.length > 32
        hex[0, 32]
      elsif hex.length < 32
        hex.ljust(32, "0")
      else
        hex
      end
    end

    # Generate a random 16-char span ID (8 bytes hex-encoded).
    def self.generate_span_id
      SecureRandom.hex(8)
    end

    # Generate a random 32-char trace ID (16 bytes hex-encoded).
    def self.generate_trace_id
      SecureRandom.hex(16)
    end
  end
end
