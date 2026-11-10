# frozen_string_literal: true

require_relative "lib/toneperfect"

Gem::Specification.new do |spec|
  spec.name = "toneperfect"
  spec.version = TonePerfect::VERSION
  spec.authors = ["TonePerfect"]
  spec.email = ["nik@toneperfect.app"]
  spec.summary = "Client for the TonePerfect pronunciation assessment API, 10 languages."
  spec.description = "Pronunciation assessment API, 10 languages: score a short scripted recording against its " \
                     "reference text and get sentence, word and sound grades. Standard library only."
  spec.homepage = "https://api.toneperfect.app"
  spec.license = "MIT"
  spec.required_ruby_version = ">= 3.0"
  spec.metadata = {
    "homepage_uri" => "https://api.toneperfect.app",
    "documentation_uri" => "https://api.toneperfect.app/docs",
    "source_code_uri" => "https://github.com/vm542/toneperfect-sdk/tree/main/ruby",
    "changelog_uri" => "https://github.com/vm542/toneperfect-sdk/blob/main/CHANGELOG.md",
    "rubygems_mfa_required" => "true"
  }
  spec.files = Dir["lib/**/*.rb", "examples/**/*.rb", "README.md", "LICENSE"]
  spec.require_paths = ["lib"]
end
