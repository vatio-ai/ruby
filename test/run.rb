# frozen_string_literal: true

# Checks this gem against the backend it talks to, by loading the backend's own
# classes rather than a copy of what they are believed to do. That is the whole
# reason the gem lives in this repo: both halves of the identity contract move
# in one commit, and a change to either that breaks the other fails here.
#
#   cd backend && bundle exec ruby ../plugins/ruby/test/run.rb
#
# Plain Ruby on purpose -- no Rails boot, no database, under a second.

require "stringio"
require "logger"
require "tmpdir"
require "active_support/core_ext/object/blank"

ROOT = File.expand_path("../../..", __dir__)
$LOAD_PATH.unshift File.join(__dir__, "..", "lib")
require "vatio/identity"

# The smallest Rails the backend files need to load outside the app.
module Rails
  LOG = StringIO.new

  def self.logger = @logger ||= Logger.new(LOG)
end

class String
  def demodulize = split("::").last
end

load File.join(ROOT, "backend/app/vatio/authentication/token.rb")
require File.join(ROOT, "backend/lib/workspace_contract/manifest_directory")

FAILURES = []

def check(label, ok)
  puts("#{ok ? "  ok  " : "  FAIL"}  #{label}")
  FAILURES << label unless ok
end

def section(name) = puts("\n#{name}")

def raises(label, fragment)
  yield
  check(label, false)
rescue Vatio::Identity::ConfigurationError, ArgumentError => e
  check(label, e.message.include?(fragment))
end

WORKSPACE_KEY = OpenSSL::PKey::EC.generate("prime256v1")
WORKSPACE_PUB = OpenSSL::PKey::EC.new(WORKSPACE_KEY.public_to_pem).to_pem
AUTH = { "public_key_pem" => WORKSPACE_PUB, "algorithm" => "ES256" }.freeze

def configure
  Vatio::Identity.instance_variable_set(:@config, nil)
  Vatio::Identity.configure do |c|
    c.audience = "acme"
    c.private_key = WORKSPACE_KEY.to_pem
  end
end

def verify_with_backend(token, audience: "acme")
  Vatio::Authentication::Token.verify(token, auth: AUTH, audience: audience)
end

configure

section "a token this gem signs, verified by the backend's own Token"
check("algorithm inferred from the curve", Vatio::Identity.config.algorithm == "ES256")
token = Vatio::Identity.token_for(subject: 42, claims: { name: "Ivan", email: "i@x.cl" })
principal = verify_with_backend(token)
check("accepted", !principal.nil?)
check("subject arrives as a string", principal&.subject == "42")
check("name and email fill the profile", principal&.profile == { "name" => "Ivan", "email" => "i@x.cl" })
check("registered claims stay out of $auth.claims", principal&.claims&.keys&.sort == %w[email name])
check("another audience is rejected", verify_with_backend(token, audience: "other").nil?)
sneaky = Vatio::Identity.token_for(subject: 42, claims: { "aud" => "victim", "sub" => "1", "exp" => 1 })
check("claims cannot override aud/sub/exp", verify_with_backend(sneaky)&.subject == "42")
check("the gem verifies its own token", Vatio::Identity.verify(token)&.subject == "42")
check("and rejects garbage", Vatio::Identity.verify("nope.nope.nope").nil?)

section "the configuration refuses to be dangerous"
raises("a public key cannot sign", "PUBLIC key") { Vatio::Identity::Config.new.private_key = WORKSPACE_PUB }
raises("a blank subject is refused", "subject cannot be blank") { Vatio::Identity.token_for(subject: " ") }

section "the manifest's auth block"
def manifest(mint)
  Dir.mktmpdir do |dir|
    File.write(File.join(dir, "identity.pub"), WORKSPACE_PUB)
    File.write(File.join(dir, "vatio.yml"), <<~YML)
      workspace: acme
      auth:
        public_key: identity.pub
      #{mint}
      agent:
        name: Acme
        instructions: Help.
    YML
    VatioManifestDirectory.load(dir)
  end
end

check("auth loads", manifest("").dig("auth", "public_key_pem") == WORKSPACE_PUB)
raises("auth.mint is refused now that Vatio never asks", "mint") do
  manifest("  mint:\n    url: https://api.acme.com/vatio/identity")
end

if FAILURES.empty?
  puts "\nok — everything passed"
else
  puts "\n#{FAILURES.size} failed:"
  FAILURES.each { |name| puts "  - #{name}" }
end
exit(FAILURES.empty? ? 0 : 1)
