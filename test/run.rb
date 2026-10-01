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
require "digest"
require "logger"
require "tmpdir"
require "active_support/core_ext/object/blank"

ROOT = File.expand_path("../../..", __dir__)
$LOAD_PATH.unshift File.join(__dir__, "..", "lib")
require "vatio/identity"

PLATFORM_KEY = OpenSSL::PKey::EC.generate("prime256v1")

# The smallest Rails the backend files need to load outside the app.
module Rails
  Credentials = Struct.new(:pem) do
    def dig(*keys) = (keys == [ :mint_signing, :private_key ] ? pem : nil)
  end
  Application = Struct.new(:credentials)

  LOG = StringIO.new

  def self.application = @application ||= Application.new(Credentials.new(PLATFORM_KEY.to_pem))

  def self.application=(value)
    @application = value
  end

  def self.logger = @logger ||= Logger.new(LOG)
end

class String
  def demodulize = split("::").last
end

load File.join(ROOT, "backend/app/vatio/authentication/token.rb")
load File.join(ROOT, "backend/app/vatio/authentication/mint_signature.rb")
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
VATIO_PUB = Vatio::Authentication::MintSignature.public_key_pem
AUTH = { "public_key_pem" => WORKSPACE_PUB, "algorithm" => "ES256" }.freeze

def configure(pin_vatio_key: true)
  Vatio::Identity.instance_variable_set(:@config, nil)
  Vatio::Identity.configure do |c|
    c.audience = "acme"
    c.private_key = WORKSPACE_KEY.to_pem
    c.mint_api_key = "s3cret-mint-key"
    c.mint_public_key = VATIO_PUB if pin_vatio_key
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

section "the mint endpoint, against signatures from the backend's MintSignature"
APP = Vatio::Identity.mint do |channel:, phone_number:|
  next nil unless channel == "whatsapp" && phone_number == "+56912345678"
  { subject: 7, claims: { name: "Known" } }
end
BODY = '{"channel":"whatsapp","phone_number":"+56912345678"}'

def post(body, api_key: "s3cret-mint-key", method: "POST", signature: :real, slug: "acme")
  env = { "REQUEST_METHOD" => method, "rack.input" => StringIO.new(body) }
  env["HTTP_X_API_KEY"] = api_key if api_key
  signature = Vatio::Authentication::MintSignature.header_for(workspace_slug: slug, body: body) if signature == :real
  env["HTTP_VATIO_SIGNATURE"] = signature if signature
  APP.call(env)
end

status, _, body = post(BODY)
check("a real signature is accepted", status == 200)
minted = status == 200 ? JSON.parse(body.first)["token"] : nil
check("the minted token verifies as user 7", verify_with_backend(minted.to_s)&.subject == "7")

check("no signature -> 404", post(BODY, signature: nil).first == 404)
check("signed for another workspace -> 404", post(BODY, slug: "other").first == 404)
tampered = '{"channel":"whatsapp","phone_number":"+56900000000"}'
for_other_body = Vatio::Authentication::MintSignature.header_for(workspace_slug: "acme", body: BODY)
check("a valid signature over another body -> 404", post(tampered, signature: for_other_body).first == 404)

now = Time.now.to_i
digest = Digest::SHA256.hexdigest(BODY)
expired = JWT.encode({ "iss" => "vatio.ai", "aud" => "acme", "iat" => now - 600, "exp" => now - 300,
                       "body_sha256" => digest }, PLATFORM_KEY, "ES256")
check("expired -> 404", post(BODY, signature: expired).first == 404)
impostor = JWT.encode({ "iss" => "vatio.ai", "aud" => "acme", "iat" => now, "exp" => now + 60,
                        "body_sha256" => digest }, OpenSSL::PKey::EC.generate("prime256v1"), "ES256")
check("signed by another key -> 404", post(BODY, signature: impostor).first == 404)
wrong_issuer = JWT.encode({ "iss" => "evil.example", "aud" => "acme", "iat" => now, "exp" => now + 60,
                            "body_sha256" => digest }, PLATFORM_KEY, "ES256")
check("wrong issuer -> 404", post(BODY, signature: wrong_issuer).first == 404)

check("no api key -> 404", post(BODY, api_key: nil).first == 404)
check("wrong api key -> 404", post(BODY, api_key: "wrong").first == 404)
check("GET -> 404", post(BODY, method: "GET").first == 404)
check("unknown number -> 404", post('{"channel":"whatsapp","phone_number":"+5699"}').first == 404)
check("unknown channel -> 404", post('{"channel":"sms","phone_number":"+56912345678"}').first == 404)
check("garbage body -> 404", post("not json").first == 404)
check("oversized body -> 404", post(%({"channel":"whatsapp","phone_number":"#{"9" * 5000}"})).first == 404)

section "the configuration refuses to be dangerous"
raises("an open mint is refused", "account takeover") do
  Vatio::Identity::Config.new.tap { |c| c.audience = "a" }.mint_api_key!
end
raises("an unpinned Vatio key is refused", "mint_public_key is required") do
  Vatio::Identity::Config.new.mint_public_key!
end
raises("a public key cannot sign", "PUBLIC key") { Vatio::Identity::Config.new.private_key = WORKSPACE_PUB }
raises("Vatio's public key cannot be a private one", "PRIVATE key") do
  Vatio::Identity::Config.new.mint_public_key = PLATFORM_KEY.to_pem
end
raises("a blank subject is refused", "subject cannot be blank") { Vatio::Identity.token_for(subject: " ") }
configure(pin_vatio_key: false)
raises("an unpinned endpoint will not serve", "mint_public_key is required") { post(BODY, signature: nil) }
configure

section "the backend cannot sign silently"
Rails.application = Rails::Application.new(Rails::Credentials.new(""))
Vatio::Authentication::MintSignature.instance_variable_set(:@keys, nil)
Rails::LOG.truncate(0)
check("no key, no header", Vatio::Authentication::MintSignature.header_for(workspace_slug: "acme", body: BODY).nil?)
logged = Rails::LOG.string
check("logged at ERROR rather than passed over", logged.include?("signing_key_missing") && logged.include?("ERROR"))
check("naming the workspace", logged.include?("acme"))
check("and no public key to serve", Vatio::Authentication::MintSignature.public_key_pem.nil?)

section "the manifest refuses a mint nobody guards"
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

URL = "https://api.acme.com/vatio/identity"
raises("a bare url is refused", "leaves the endpoint") { manifest("  mint: #{URL}") }
raises("no headers is refused", "headers is required") { manifest("  mint:\n    url: #{URL}") }
raises("empty headers is refused", "headers is required") { manifest("  mint:\n    url: #{URL}\n    headers: {}") }
raises("a blank header value is refused", "headers is required") do
  manifest(%(  mint:\n    url: #{URL}\n    headers:\n      X-Api-Key: ""))
end
raises("a literal credential is refused", "no $env. placeholder") do
  manifest("  mint:\n    url: #{URL}\n    headers:\n      X-Api-Key: hunter2")
end
raises("routing alone is not a credential", "no $env. placeholder") do
  manifest("  mint:\n    url: #{URL}\n    headers:\n      X-Tenant: acme")
end
check("an $env. credential is accepted",
  !manifest("  mint:\n    url: $env.API_URL/i\n    headers:\n      X-Api-Key: $env.K").dig("auth", "mint", "headers").empty?)
check("routing alongside a credential is accepted",
  manifest("  mint:\n    url: #{URL}\n    headers:\n      X-Tenant: acme\n      X-Api-Key: $env.K")
    .dig("auth", "mint", "headers").size == 2)
check("auth without mint is untouched", manifest("").dig("auth", "mint").nil?)

if FAILURES.empty?
  puts "\nok — everything passed"
else
  puts "\n#{FAILURES.size} failed:"
  FAILURES.each { |name| puts "  - #{name}" }
end
exit(FAILURES.empty? ? 0 : 1)
