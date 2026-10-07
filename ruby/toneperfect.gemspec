# frozen_string_literal: true

require_relative "lib/toneperfect"

Gem::Specification.new do |spec|
  spec.name = "toneperfect"
  spec.version = TonePerfect::VERSION
  spec.authors = ["TonePerfect"]
  spec.email = ["nik@toneperfect.app"]
  spec.summary = "Client for the TonePerfect pronunciation assessment API."
  spec.description = "Score a short scripted recording against its reference text: sentence, word and sound " \
                     "grades, with a separate initial, final and tone score for every Mandarin syllable. " \
                     "Ten languages. Standard library only."
  spec.homepage = "https://api.toneperfect.app"
  spec.license = "MIT"
  spec.required_ruby_version = ">= 2.7"
  spec.metadata = {
    "homepage_uri" => "https://api.toneperfect.app",
    "documentation_uri" => "https://api.toneperfect.app/docs",
    "rubygems_mfa_required" => "true"
  }
  spec.files = Dir["lib/**/*.rb", "examples/**/*.rb", "README.md", "LICENSE"]
  spec.require_paths = ["lib"]
end
