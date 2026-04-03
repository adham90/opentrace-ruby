# frozen_string_literal: true

require "securerandom"

module OpenTrace
  module ULID
    # Crockford Base32 alphabet (excludes I, L, O, U)
    ENCODING = "0123456789ABCDEFGHJKMNPQRSTVWXYZ"

    MUTEX = Mutex.new
    private_constant :MUTEX

    # Generates a ULID string (26 characters, Crockford Base32 encoded).
    #
    # The first 10 characters encode the current time in milliseconds,
    # ensuring lexicographic sort order by creation time.
    # The last 16 characters are cryptographically random.
    #
    # Thread-safe: concurrent calls are serialized via a mutex to guarantee
    # uniqueness even when called from multiple threads simultaneously.
    def self.generate
      MUTEX.synchronize do
        timestamp_ms = (Process.clock_gettime(Process::CLOCK_REALTIME, :millisecond))
        randomness = SecureRandom.random_bytes(10)

        encode_timestamp(timestamp_ms) + encode_random(randomness)
      end
    end

    # Encodes a millisecond timestamp into 10 Crockford Base32 characters.
    def self.encode_timestamp(ms)
      result = String.new(capacity: 10)
      9.downto(0) do |i|
        result << ENCODING[(ms >> (5 * i)) & 0x1F]
      end
      result
    end

    # Encodes 10 random bytes into 16 Crockford Base32 characters.
    def self.encode_random(bytes)
      # Pack 10 bytes (80 bits) into 16 base32 characters (80 bits)
      # Process as a single 80-bit integer to avoid bit-boundary issues
      value = bytes.each_byte.reduce(0) { |acc, b| (acc << 8) | b }

      result = String.new(capacity: 16)
      15.downto(0) do |i|
        result << ENCODING[(value >> (5 * i)) & 0x1F]
      end
      result
    end

    private_class_method :encode_timestamp, :encode_random
  end
end
