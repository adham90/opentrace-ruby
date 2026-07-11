# frozen_string_literal: true

module OpenTrace
  # Mixin for the opt-in background monitors (pool/queue/runtime).
  #
  # Threads do not survive fork(), so a monitor started in a forking web server's
  # master process (e.g. Puma) is dead in every worker — @running stays true (it
  # was copied across the fork) but the thread is gone, so plain #start is a
  # no-op. #restart_after_fork! detects the PID change and starts a fresh thread.
  #
  # Wire it from the host's after-fork callback, e.g. in config/puma.rb:
  #   on_worker_boot { OpenTrace::Railtie.restart_monitors_after_fork! }
  module ForkSafeMonitor
    # Restart the monitor thread if we've crossed a fork boundary since #start.
    # Returns true if a restart happened, false otherwise. Never raises.
    def restart_after_fork!
      return false unless @running && @pid && @pid != Process.pid

      @running = false
      @thread = nil
      start
      true
    rescue StandardError
      false
    end
  end
end
