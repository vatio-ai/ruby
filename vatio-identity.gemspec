# frozen_string_literal: true

require_relative "lib/vatio/identity/version"

Gem::Specification.new do |spec|
  spec.name = "vatio-identity"
  spec.version = Vatio::Identity::VERSION
  spec.authors = [ "Urcalab" ]
  spec.summary = "Sign and verify the JWT a Vatio workspace authenticates its users with."
  spec.description = <<~TEXT
    Vatio holds only the public half of your signing key, so it can verify a
    token and never mint one. Everything dangerous about that arrangement is
    therefore on your side: this gem signs the token for the widget, mounts the
    mint endpoint WhatsApp needs, and verifies the same token back on your own
    API -- with the credential check that an open mint endpoint is missing.
  TEXT
  spec.homepage = "https://github.com/vatio-ai/ruby"
  spec.license = "MIT"
  spec.required_ruby_version = ">= 3.0"
  spec.metadata = {
    "source_code_uri" => "https://github.com/vatio-ai/ruby",
    "bug_tracker_uri" => "https://github.com/vatio-ai/ruby/issues",
    "documentation_uri" => "https://docs.vatio.ai/authentication/sessions"
  }

  spec.files = Dir["lib/**/*.rb", "README.md", "LICENSE.txt"]
  spec.require_paths = [ "lib" ]

  spec.add_dependency "jwt", ">= 2.7"
end
