# frozen_string_literal: true

require_relative "fork_safe_monitor"

module OpenTrace
  class RuntimeMonitor
    include ForkSafeMonitor

    DEFAULT_INTERVAL = 30 # seconds

    def initialize(interval: DEFAULT_INTERVAL)
      @interval = interval
      @thread = nil
      @running = false
      @pid = nil
    end

    def start
      return if @running
      @running = true
      @pid = Process.pid
      @thread = Thread.new { monitor_loop }
      @thread.abort_on_exception = false
      @thread.report_on_exception = false
    end

    def stop
      @running = false
      @thread&.join(2)
    end

    def running?
      @running && @thread&.alive?
    end

    private

    def monitor_loop
      while @running
        sleep @interval
        next unless @running && OpenTrace.enabled?
        collect_and_send
      end
    rescue StandardError
      # Swallow
    end

    def collect_and_send
      gc = GC.stat
      metrics = {
        gc_count: gc[:count],
        gc_major_count: gc[:major_gc_count],
        gc_minor_count: gc[:minor_gc_count],
        gc_heap_live_slots: gc[:heap_live_slots],
        gc_heap_free_slots: gc[:heap_free_slots],
        gc_heap_allocated_pages: gc[:heap_allocated_pages],
        gc_malloc_increase_bytes: gc[:malloc_increase_bytes],
        gc_oldmalloc_increase_bytes: gc[:oldmalloc_increase_bytes],
        thread_count: Thread.list.count,
        process_rss_mb: current_rss_mb,
        process_pid: Process.pid
      }.compact

      OpenTrace.event("runtime.metrics", "Runtime metrics snapshot", metrics)
    rescue StandardError
      # Swallow
    end

    def current_rss_mb
      if RUBY_PLATFORM.include?("linux")
        File.read("/proc/self/statm").split[1].to_i * 4096.0 / 1024 / 1024
      else
        # macOS/other: use GC.stat as lightweight approximation
        gc = GC.stat
        gc[:heap_live_slots].to_f * 40 / 1024 / 1024
      end
    rescue StandardError
      nil
    end
  end
end
