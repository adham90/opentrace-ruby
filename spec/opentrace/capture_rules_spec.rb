# frozen_string_literal: true

require "spec_helper"
require "opentrace/capture_rules"

RSpec.describe OpenTrace::CaptureRules do
  def env_for(path)
    { "PATH_INFO" => path }
  end

  describe "level ordering" do
    it "defines :none < :minimal < :standard < :full" do
      order = OpenTrace::CaptureRules::LEVEL_ORDER
      expect(order[:none]).to be < order[:minimal]
      expect(order[:minimal]).to be < order[:standard]
      expect(order[:standard]).to be < order[:full]
    end
  end

  describe "#resolve with no rules" do
    it "returns the base level when no rules are defined" do
      rules = described_class.new
      expect(rules.resolve(env_for("/anything"))).to eq(:standard)
    end

    it "returns a custom base level when provided" do
      rules = described_class.new
      expect(rules.resolve(env_for("/anything"), base_level: :minimal)).to eq(:minimal)
    end
  end

  describe "path rules" do
    it "returns the level from a matching path rule" do
      rules = described_class.new do |r|
        r.on_path("/api/**") { :full }
      end

      expect(rules.resolve(env_for("/api/users"))).to eq(:full)
    end

    it "returns base level when no path rule matches" do
      rules = described_class.new do |r|
        r.on_path("/api/**") { :full }
      end

      expect(rules.resolve(env_for("/dashboard"))).to eq(:standard)
    end

    describe "** wildcard" do
      it "matches nested paths" do
        rules = described_class.new do |r|
          r.on_path("/api/**") { :full }
        end

        expect(rules.resolve(env_for("/api/users"))).to eq(:full)
        expect(rules.resolve(env_for("/api/users/42/edit"))).to eq(:full)
        expect(rules.resolve(env_for("/api/v2/users/42/posts/99"))).to eq(:full)
      end

      it "does not match unrelated paths" do
        rules = described_class.new do |r|
          r.on_path("/api/**") { :full }
        end

        expect(rules.resolve(env_for("/admin/users"))).to eq(:standard)
      end
    end

    describe "* wildcard" do
      it "matches a single path segment" do
        rules = described_class.new do |r|
          r.on_path("/api/*") { :full }
        end

        expect(rules.resolve(env_for("/api/users"))).to eq(:full)
      end

      it "does not match nested paths" do
        rules = described_class.new do |r|
          r.on_path("/api/*") { :full }
        end

        expect(rules.resolve(env_for("/api/users/42"))).to eq(:standard)
      end
    end

    it "uses the first matching path rule" do
      rules = described_class.new do |r|
        r.on_path("/api/**") { :minimal }
        r.on_path("/api/admin/**") { :full }
      end

      # /api/admin/settings matches /api/** first
      expect(rules.resolve(env_for("/api/admin/settings"))).to eq(:minimal)
    end
  end

  describe "on_error" do
    it "upgrades the level when error is true" do
      rules = described_class.new do |r|
        r.on_path("/assets/**") { :none }
        r.on_error { :full }
      end

      expect(rules.resolve(env_for("/assets/style.css"), error: true)).to eq(:full)
    end

    it "does not upgrade when error is false" do
      rules = described_class.new do |r|
        r.on_path("/assets/**") { :none }
        r.on_error { :full }
      end

      expect(rules.resolve(env_for("/assets/style.css"), error: false)).to eq(:none)
    end

    it "upgrades base level when no path rule matches" do
      rules = described_class.new do |r|
        r.on_error { :full }
      end

      expect(rules.resolve(env_for("/anything"), base_level: :minimal, error: true)).to eq(:full)
    end
  end

  describe "on_slow" do
    it "upgrades the level when duration exceeds threshold" do
      rules = described_class.new do |r|
        r.on_slow(threshold: 500) { :full }
      end

      expect(rules.resolve(env_for("/page"), duration_ms: 600)).to eq(:full)
    end

    it "does not upgrade when duration is below threshold" do
      rules = described_class.new do |r|
        r.on_slow(threshold: 500) { :full }
      end

      expect(rules.resolve(env_for("/page"), duration_ms: 200)).to eq(:standard)
    end

    it "does not upgrade when duration equals threshold" do
      rules = described_class.new do |r|
        r.on_slow(threshold: 500) { :full }
      end

      expect(rules.resolve(env_for("/page"), duration_ms: 500)).to eq(:standard)
    end

    it "does not upgrade when duration_ms is nil" do
      rules = described_class.new do |r|
        r.on_slow(threshold: 500) { :full }
      end

      expect(rules.resolve(env_for("/page"))).to eq(:standard)
    end
  end

  describe "never downgrades" do
    it "keeps :full when on_error returns :standard" do
      rules = described_class.new do |r|
        r.on_path("/api/**") { :full }
        r.on_error { :standard }
      end

      expect(rules.resolve(env_for("/api/users"), error: true)).to eq(:full)
    end

    it "keeps :full when on_slow returns :minimal" do
      rules = described_class.new do |r|
        r.on_path("/api/**") { :full }
        r.on_slow(threshold: 100) { :minimal }
      end

      expect(rules.resolve(env_for("/api/users"), duration_ms: 200)).to eq(:full)
    end
  end

  describe "#resolve_domain" do
    let(:rules) { described_class.new }

    it "returns the override when set for the domain" do
      overrides = { "api.example.com" => :full, "admin.example.com" => :minimal }
      expect(rules.resolve_domain("api.example.com", :standard, overrides)).to eq(:full)
    end

    it "returns resolved_level when domain has no override" do
      overrides = { "api.example.com" => :full }
      expect(rules.resolve_domain("other.example.com", :standard, overrides)).to eq(:standard)
    end

    it "returns resolved_level when overrides hash is empty" do
      expect(rules.resolve_domain("any.example.com", :minimal, {})).to eq(:minimal)
    end

    it "uses the override even if it is a lower level" do
      overrides = { "static.example.com" => :none }
      expect(rules.resolve_domain("static.example.com", :full, overrides)).to eq(:none)
    end
  end

  describe "combined rules" do
    it "applies path + error + slow together" do
      rules = described_class.new do |r|
        r.on_path("/api/**")       { :minimal }
        r.on_path("/admin/**")     { :full }
        r.on_path("/assets/**")    { :none }
        r.on_error                 { :full }
        r.on_slow(threshold: 500)  { :full }
      end

      # Path match only
      expect(rules.resolve(env_for("/api/users"))).to eq(:minimal)
      expect(rules.resolve(env_for("/admin/dashboard"))).to eq(:full)
      expect(rules.resolve(env_for("/assets/logo.png"))).to eq(:none)

      # Error upgrades :none to :full
      expect(rules.resolve(env_for("/assets/broken.css"), error: true)).to eq(:full)

      # Slow upgrades :minimal to :full
      expect(rules.resolve(env_for("/api/users"), duration_ms: 600)).to eq(:full)

      # No path match falls back to base, then slow upgrades
      expect(rules.resolve(env_for("/unknown"), base_level: :minimal, duration_ms: 600)).to eq(:full)
    end
  end
end
