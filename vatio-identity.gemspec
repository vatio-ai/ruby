# frozen_string_literal: true

# The gem's name until 0.6.0. Kept so a Gemfile that still says
# `gem "vatio-identity", git: "https://github.com/vatio-ai/ruby"` installs
# vatio-sdk instead of failing; it ships no code of its own.

require_relative "lib/vatio/identity/version"

Gem::Specification.new do |spec|
  spec.name = "vatio-identity"
  spec.version = Vatio::Identity::VERSION
  spec.authors = [ "Urcalab" ]
  spec.summary = "Renamed to vatio-sdk."
  spec.homepage = "https://github.com/vatio-ai/ruby"
  spec.license = "MIT"
  spec.required_ruby_version = ">= 3.0"

  spec.files = []
  spec.require_paths = [ "lib" ]

  spec.add_dependency "vatio-sdk", Vatio::Identity::VERSION
end
