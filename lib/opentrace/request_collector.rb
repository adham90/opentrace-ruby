# frozen_string_literal: true

module OpenTrace
  class RequestCollector
    MAX_TIMELINE_EVENTS = 200

    attr_reader :sql_count, :sql_total_ms,
                :view_count, :view_total_ms,
                :cache_reads, :cache_hits, :cache_writes,
                :http_count, :http_total_ms
    attr_accessor :memory_before, :memory_after

    def initialize(max_timeline: MAX_TIMELINE_EVENTS)
      @max_timeline = max_timeline

      @sql_count = 0
      @sql_total_ms = 0.0
      @sql_slowest_ms = 0.0
      @sql_slowest_name = nil

      @view_count = 0
      @view_total_ms = 0.0
      @view_slowest_ms = 0.0
      @view_slowest_template = nil

      @cache_reads = 0
      @cache_hits = 0
      @cache_writes = 0
      @cache_deletes = 0

      @http_count = 0
      @http_total_ms = 0.0
      @http_slowest_ms = 0.0
      @http_slowest_host = nil

      @memory_before = nil
      @memory_after = nil

      @timeline = []
      @request_start = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    end

    def record_sql(name:, duration_ms:, table: nil)
      @sql_count += 1
      @sql_total_ms += duration_ms

      if duration_ms > @sql_slowest_ms
        @sql_slowest_ms = duration_ms
        @sql_slowest_name = name
      end

      append_timeline({ t: :sql, n: name, ms: duration_ms.round(1), at: offset_ms })
    end

    def record_view(template:, duration_ms:)
      @view_count += 1
      @view_total_ms += duration_ms

      if duration_ms > @view_slowest_ms
        @view_slowest_ms = duration_ms
        @view_slowest_template = template
      end

      append_timeline({ t: :view, n: template, ms: duration_ms.round(1), at: offset_ms })
    end

    def record_cache(action:, hit: nil, duration_ms: 0.0)
      case action
      when :read
        @cache_reads += 1
        @cache_hits += 1 if hit
      when :write
        @cache_writes += 1
      when :delete
        @cache_deletes += 1
      end

      append_timeline({ t: :cache, a: action, hit: hit, ms: duration_ms.round(2), at: offset_ms })
    end

    def record_http(method:, url:, host:, status:, duration_ms:, error: nil)
      @http_count += 1
      @http_total_ms += duration_ms

      if duration_ms > @http_slowest_ms
        @http_slowest_ms = duration_ms
        @http_slowest_host = host
      end

      entry = { t: :http, n: "#{method} #{host}", ms: duration_ms.round(1), s: status, at: offset_ms }
      entry[:err] = error if error
      append_timeline(entry)
    end

    def summary
      result = {
        sql_query_count: @sql_count,
        sql_total_ms: @sql_total_ms.round(1),
        sql_slowest_ms: @sql_slowest_ms.round(1),
        sql_slowest_name: @sql_slowest_name,
        view_render_count: @view_count,
        view_total_ms: @view_total_ms.round(1),
        view_slowest_ms: @view_slowest_ms.round(1),
        view_slowest_template: @view_slowest_template,
        cache_reads: @cache_reads,
        cache_hits: @cache_hits,
        cache_writes: @cache_writes,
        cache_hit_ratio: @cache_reads > 0 ? (@cache_hits.to_f / @cache_reads).round(2) : nil,
        n_plus_one_warning: @sql_count > 20 ? true : nil,
        timeline: @timeline.empty? ? nil : @timeline
      }

      # HTTP stats (only present if calls were made)
      if @http_count > 0
        result[:http_external_count] = @http_count
        result[:http_external_total_ms] = @http_total_ms.round(1)
        result[:http_slowest_ms] = @http_slowest_ms.round(1)
        result[:http_slowest_host] = @http_slowest_host
      end

      # Memory stats (only present if memory_tracking is enabled)
      if @memory_before && @memory_after
        result[:memory_before_mb] = @memory_before
        result[:memory_after_mb] = @memory_after
        result[:memory_delta_mb] = (@memory_after - @memory_before).round(1)
      end

      result.compact
    end

    private

    def offset_ms
      ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - @request_start) * 1000).round(1)
    end

    def append_timeline(entry)
      @timeline << entry if @timeline.size < @max_timeline
    end
  end
end
