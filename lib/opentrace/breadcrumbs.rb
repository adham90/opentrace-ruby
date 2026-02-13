# frozen_string_literal: true

module OpenTrace
  class Breadcrumb
    attr_reader :category, :message, :data, :timestamp, :level

    def initialize(category:, message:, data: nil, level: "info")
      @category = category.to_s
      @message = message.to_s
      @data = data
      @level = level.to_s
      @timestamp = Process.clock_gettime(Process::CLOCK_REALTIME)
    end

    def to_h
      h = { category: @category, message: @message, level: @level, timestamp: @timestamp }
      h[:data] = @data if @data
      h
    end
  end

  class BreadcrumbBuffer
    MAX_BREADCRUMBS = 25

    def initialize
      @buffer = []
    end

    def add(breadcrumb)
      @buffer.shift if @buffer.size >= MAX_BREADCRUMBS
      @buffer << breadcrumb
    end

    def to_a
      @buffer.map(&:to_h)
    end

    def empty?
      @buffer.empty?
    end

    def size
      @buffer.size
    end
  end
end
