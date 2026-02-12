# frozen_string_literal: true

module OpenTrace
  class RequestCollector
    MAX_TIMELINE_EVENTS = 200

    attr_reader :sql_count, :sql_total_ms,
                :view_count, :view_total_ms,
                :cache_reads, :cache_hits, :cache_writes

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
