# frozen_string_literal: true

module OpenTrace
  class CaptureRules
    LEVELS = %i[none minimal standard full].freeze
    LEVEL_ORDER = LEVELS.each_with_index.to_h.freeze # { none: 0, minimal: 1, standard: 2, full: 3 }

    def initialize(&block)
      @path_rules = []
      @error_rule = nil
      @slow_rule = nil

      block&.call(self)
    end

    # Register a path-matching rule. Pattern supports:
    #   ** — matches any number of path segments (including zero)
    #   *  — matches exactly one path segment
    def on_path(pattern, &block)
      regex = path_pattern_to_regex(pattern)
      @path_rules << { regex: regex, block: block }
    end

    # Register a rule that fires when the request resulted in an error.
    def on_error(&block)
      @error_rule = block
    end

    # Register a rule that fires when the request duration exceeds a threshold.
    # threshold is in milliseconds.
    def on_slow(threshold:, &block)
      @slow_rule = { threshold: threshold, block: block }
    end

    # Evaluate all rules for a given request and return the final capture level.
    #
    # env          — Rack env hash (must contain "PATH_INFO")
    # base_level   — fallback level when no path rule matches (default :standard)
    # status       — HTTP response status (not used directly, reserved)
    # duration_ms  — request duration in milliseconds (for on_slow)
    # error        — whether the request raised an error (for on_error)
    def resolve(env, base_level: :standard, status: nil, duration_ms: nil, error: false)
      level = resolve_path(env) || base_level

      # Post-request upgrades: only go up, never down
      if error && @error_rule
        error_level = @error_rule.call
        level = max_level(level, error_level)
      end

      if duration_ms && @slow_rule && duration_ms > @slow_rule[:threshold]
        slow_level = @slow_rule[:block].call
        level = max_level(level, slow_level)
      end

      level
    end

    # Apply per-domain overrides. If the domain has an explicit override, use it.
    # Otherwise return the resolved_level as-is.
    def resolve_domain(domain, resolved_level, overrides)
      override = overrides[domain]
      override.nil? ? resolved_level : override
    end

    private

    # Find the first path rule that matches and return its level.
    # Returns nil if no rule matches.
    def resolve_path(env)
      path = env["PATH_INFO"].to_s

      @path_rules.each do |rule|
        return rule[:block].call if rule[:regex].match?(path)
      end

      nil
    end

    # Return whichever level is higher in the ordering.
    def max_level(a, b)
      (LEVEL_ORDER[a] || 0) >= (LEVEL_ORDER[b] || 0) ? a : b
    end

    # Convert a path pattern to a regex.
    #   ** → matches any characters (including /)
    #   *  → matches any characters except /
    #
    # Processing order matters: replace ** first (as a distinct token),
    # then replace remaining single *.
    def path_pattern_to_regex(pattern)
      # Escape everything except our wildcards
      # Step 1: Replace ** with a unique placeholder
      escaped = pattern.gsub("**", "\x00DOUBLE\x00")
      # Step 2: Replace remaining single * with a placeholder
      escaped = escaped.gsub("*", "\x00SINGLE\x00")
      # Step 3: Escape regex metacharacters in the rest
      escaped = Regexp.escape(escaped)
      # Step 4: Restore placeholders with regex patterns
      escaped = escaped.gsub("\x00DOUBLE\x00", ".*")
      escaped = escaped.gsub("\x00SINGLE\x00", "[^/]+")

      Regexp.new("\\A#{escaped}\\z")
    end
  end
end
