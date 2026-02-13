# frozen_string_literal: true

module OpenTrace
  class Sampler
    MAX_BACKPRESSURE = 10 # 2^10 = 1024x reduction

    def initialize(config)
      @config = config
      @backpressure = 0
    end

    def sample?(env = nil)
      rate = effective_rate(env)
      return true if rate >= 1.0
      return false if rate <= 0.0
      rand < rate
    end

    def effective_rate(env = nil)
      base = if @config.sampler
               @config.sampler.call(env) rescue @config.sample_rate
             else
               @config.sample_rate
             end
      return base if @backpressure == 0
      base / (1 << @backpressure)
    end

    def increase_backpressure!
      @backpressure = [@backpressure + 1, MAX_BACKPRESSURE].min
    end

    def decrease_backpressure!
      @backpressure = [@backpressure - 1, 0].max
    end

    def backpressure_level
      @backpressure
    end
  end
end
