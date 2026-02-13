# frozen_string_literal: true

module OpenTrace
  module SourceContext
    CONTEXT_LINES = 3  # lines before and after the error line
    MAX_CACHE_SIZE = 50
    MAX_FILE_SIZE = 100_000 # 100KB — skip generated/minified files

    @cache = {}
    @mutex = Mutex.new

    module_function

    # Extract source code context around a backtrace line.
    # Returns nil if the file can't be read.
    def extract(backtrace_line)
      match = backtrace_line&.match(/\A(.+):(\d+)/)
      return nil unless match

      file = match[1]
      line_no = match[2].to_i
      return nil if line_no <= 0

      full_path = resolve_path(file)
      return nil unless full_path && File.exist?(full_path)
      return nil unless safe_path?(full_path)

      lines = read_file_lines(full_path)
      return nil unless lines

      start_line = [line_no - CONTEXT_LINES, 1].max
      end_line = [line_no + CONTEXT_LINES, lines.size].min

      context = {}
      (start_line..end_line).each do |n|
        context[n] = lines[n - 1]&.rstrip&.slice(0, 200)
      end

      {
        file: file,
        line: line_no,
        context: context
      }
    rescue StandardError
      nil
    end

    def resolve_path(file)
      if file.start_with?("/")
        file
      elsif defined?(::Rails) && ::Rails.respond_to?(:root) && ::Rails.root
        File.join(::Rails.root.to_s, file)
      else
        File.expand_path(file)
      end
    rescue StandardError
      nil
    end

    def safe_path?(path)
      return false unless path.include?("/app/") || path.include?("/lib/") || path.include?("/config/")
      File.size(path) <= MAX_FILE_SIZE
    rescue StandardError
      false
    end

    def read_file_lines(path)
      @mutex.synchronize do
        return @cache[path] if @cache.key?(path)

        if @cache.size >= MAX_CACHE_SIZE
          @cache.delete(@cache.keys.first)
        end

        lines = File.readlines(path)
        @cache[path] = lines
        lines
      end
    rescue StandardError
      nil
    end

    def clear_cache!
      @mutex.synchronize { @cache.clear }
    end
  end
end
