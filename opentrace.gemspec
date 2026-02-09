# frozen_string_literal: true

require_relative "lib/opentrace/version"

Gem::Specification.new do |spec|
  spec.name          = "opentrace"
  spec.version       = OpenTrace::VERSION
  spec.authors       = ["OpenTrace"]
  spec.email         = ["hello@opentrace.dev"]

  spec.summary       = "Thin, safe Ruby client for OpenTrace log ingestion"
  spec.description   = "Forwards structured application logs to an OpenTrace server over HTTP. " \
                        "Designed to never affect application behavior or uptime."
  spec.homepage      = "https://github.com/adham90/opentrace-ruby"
  spec.license       = "MIT"

  spec.required_ruby_version = ">= 3.0.0"

  spec.files         = Dir["lib/**/*.rb", "LICENSE", "README.md"]
  spec.require_paths = ["lib"]

  # logger was removed from default gems in Ruby 4.0
  spec.add_dependency "logger"
end
