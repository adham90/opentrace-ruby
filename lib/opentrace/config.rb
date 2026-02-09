# frozen_string_literal: true

module OpenTrace
  class Config
    REQUIRED_FIELDS = %i[endpoint api_key service].freeze
    LEVELS = { debug: 0, info: 1, warn: 2, error: 3, fatal: 4 }.freeze

    attr_accessor :endpoint, :api_key, :service, :environment, :timeout, :enabled,
                  :context, :min_level, :hostname, :pid, :git_sha

    def initialize
      @endpoint    = nil
      @api_key     = nil
      @service     = nil
      @environment = nil
      @timeout     = 1.0
      @enabled     = true
      @context     = nil    # nil | Hash | Proc
      @min_level   = :debug # send everything by default
      @hostname    = nil
      @pid         = nil
      @git_sha     = nil
    end

    def valid?
      REQUIRED_FIELDS.all? { |f| value = send(f); value.is_a?(String) && !value.empty? }
    end

    def enabled?
      @enabled && valid?
    end

    def min_level_value
      LEVELS[min_level.to_s.downcase.to_sym] || 0
    end
  end
end
