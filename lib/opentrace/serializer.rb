# frozen_string_literal: true

require "json"
require "msgpack"

module OpenTrace
  # Handles serialization of documents for the wire format.
  # Uses MessagePack by default (5-10x faster, 30% smaller).
  # Falls back to JSON if msgpack is unavailable or for debugging.
  module Serializer
    MSGPACK_CONTENT_TYPE = "application/msgpack"
    JSON_CONTENT_TYPE    = "application/json"

    module_function

    # Serialize a document (Hash or Array) for transmission.
    # Returns [encoded_bytes, content_type]
    def encode(data, format: :msgpack)
      case format
      when :msgpack
        [MessagePack.pack(data), MSGPACK_CONTENT_TYPE]
      when :json
        [JSON.generate(data), JSON_CONTENT_TYPE]
      else
        raise ArgumentError, "Unknown serialization format: #{format}"
      end
    rescue StandardError => e
      # If msgpack fails (e.g., unsupported type), fall back to JSON
      if format == :msgpack
        [JSON.generate(data), JSON_CONTENT_TYPE]
      else
        raise
      end
    end

    # Decode bytes received from the wire.
    # content_type determines the decoder.
    def decode(bytes, content_type: MSGPACK_CONTENT_TYPE)
      case content_type
      when MSGPACK_CONTENT_TYPE
        MessagePack.unpack(bytes)
      when JSON_CONTENT_TYPE
        JSON.parse(bytes)
      else
        JSON.parse(bytes) # default to JSON for unknown types
      end
    end

    # Estimate byte size of a document without full serialization.
    # Used for buffer tracking — rough estimate is fine.
    def estimate_size(data)
      case data
      when String then data.bytesize
      when Hash   then data.sum { |k, v| k.to_s.bytesize + estimate_size(v) } + 2
      when Array  then data.sum { |v| estimate_size(v) } + 2
      when Numeric then 8
      when NilClass, TrueClass, FalseClass then 1
      else
        data.to_s.bytesize
      end
    end
  end
end
