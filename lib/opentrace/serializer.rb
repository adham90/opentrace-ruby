# frozen_string_literal: true

require "json"

module OpenTrace
  # JSON serialization helpers. The client sends JSON on the wire
  # (see Client#send_batch). MessagePack was never actually used — the only
  # caller of the old msgpack path was the (now removed) Pipeline — so the
  # native `msgpack` dependency was dropped to keep `gem install` extension-free.
  module Serializer
    JSON_CONTENT_TYPE = "application/json"

    module_function

    # Estimate byte size of a document without full serialization.
    # Used for buffer/queue tracking — a rough estimate is fine.
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
