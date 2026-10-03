# frozen_string_literal: true

require "jwt"
require "openssl"

require_relative "identity/version"
require_relative "identity/config"

module Vatio
  # Signs the one credential Vatio accepts, and verifies it on the way back.
  #
  # Vatio holds only the public half of the key, so the most it can do is
  # check: it cannot mint a token for one of your users. That is the property
  # that makes it reasonable for a platform to be verifying identity at all --
  # and it is also why every way this can go wrong lives on this side of the
  # line, in your application, which is what this library is for.
  #
  #   Vatio::Identity.configure do |c|
  #     c.audience    = "acme"                        # your workspace slug
  #     c.private_key = ENV["VATIO_IDENTITY_PRIVATE_KEY"]
  #   end
  module Identity
    Error = Class.new(StandardError)
    ConfigurationError = Class.new(Error)

    # The same leeway Vatio verifies with. Clocks disagree by seconds; a minute
    # covers the drift between two servers and is far too short to matter to
    # anyone holding an expired token.
    LEEWAY = 60

    # `exp` because a token with no expiry is a permanent credential sitting in
    # page source. `aud` because a signature proves who signed, not what for:
    # without it any other JWT you sign with this key -- a password reset, a
    # download link -- is accepted as an identity, since it also has a `sub`.
    REQUIRED_CLAIMS = %w[sub exp aud].freeze

    # Carried by every JWT and meaningful to the protocol rather than to you,
    # so they are stripped back out of `claims` on the way in.
    REGISTERED_CLAIMS = %w[iss sub aud exp nbf iat jti].freeze

    Principal = Struct.new(:subject, :claims, :token, keyword_init: true)

    SIGN_IN_HOST = "https://vatio.ai"
    SIGN_IN_CODE = /\A[A-Za-z0-9_-]{16,64}\z/

    # A week rather than the widget's hour. The widget gets a fresh token on
    # every page load; a WhatsApp contact keeps this one until it expires and
    # then has to sign in again, so an hour would mean signing in for every
    # conversation. Pass `expires_in:` to choose otherwise.
    SIGN_IN_EXPIRES_IN = 7 * 24 * 3600

    class << self
      def config
        @config ||= Config.new
      end

      def configure
        yield config
        config
      end

      # A signed token for one of your users, ready to hand to the widget.
      #
      # Registered claims are merged last on purpose: a caller passing
      # `aud:` or `exp:` in `claims` is either confused or being creative with
      # someone else's session, and neither is worth honouring.
      def token_for(subject:, claims: {}, expires_in: nil)
        subject = subject.to_s.strip
        raise ArgumentError, "vatio identity: subject cannot be blank" if subject.empty?

        now = Time.now.to_i
        payload = stringify(claims).merge(
          "sub" => subject,
          "aud" => config.audience!,
          "iat" => now,
          "exp" => now + (expires_in || config.expires_in).to_i
        )

        JWT.encode(payload, config.private_key, config.algorithm)
      end

      # The other half, for your own API: a private tool forwards the same JWT
      # as `$auth.token`, and the endpoint behind it has to check the signature
      # itself rather than trust the caller. Returns nil for anything that does
      # not verify -- expired, wrong key, wrong audience, absent.
      #
      # Nil is not an error. It means "not signed in", which on the web is the
      # normal state of a visitor reading a marketing page.
      def verify(raw)
        raw = raw.to_s.strip
        return nil if raw.empty?

        payload, = JWT.decode(
          raw, config.public_key, true,
          # Pinned, never read from the token's header.
          algorithms: [ config.algorithm ],
          required_claims: REQUIRED_CLAIMS.dup,
          verify_expiration: true,
          leeway: LEEWAY,
          aud: config.audience!,
          verify_aud: true
        )

        Principal.new(
          subject: payload["sub"].to_s,
          claims: payload.reject { |k, _| REGISTERED_CLAIMS.include?(k) },
          token: raw
        )
      rescue JWT::DecodeError
        nil
      end

      # The script tag, with the token on it only when somebody is signed in.
      #
      # Beware of caching. Rails renders this per request, so it is safe by
      # default -- but the moment this fragment lands in a page cache, a CDN,
      # or `caches_action`, you are serving one customer's identity to the
      # next visitor. If anything caches this page, render it without a token
      # and call `window.VatioWidget.identify(token)` from an uncached
      # endpoint instead.
      def widget_tag(workspace:, token:, subject: nil, claims: {}, **attrs)
        visitor = subject && token_for(subject: subject, claims: claims)
        pairs = {
          "src" => "https://cdn.vatio.ai/v1/widget.js",
          "async" => "async",
          "data-workspace" => workspace,
          "data-token" => token,
          "data-visitor-token" => visitor
        }.merge(attrs.transform_keys { |k| "data-#{k.to_s.tr("_", "-")}" }).compact

        "<script #{pairs.map { |k, v| %(#{k}="#{escape(v)}") }.join(" ")}></script>"
      end

      # Where to send someone who tapped "Sign in" on WhatsApp or Instagram,
      # once they are signed in to your site. The page at `auth.sign_in_url`
      # receives `?code=...`; redirect to this with that code and the same
      # subject and claims you would put on the widget.
      #
      # The host is fixed on purpose. A url taken from the request would let
      # anyone who can craft a link have your server sign a token for whoever
      # opens it and hand it to them.
      def sign_in_redirect_url(code:, subject:, claims: {}, expires_in: SIGN_IN_EXPIRES_IN)
        code = code.to_s
        raise ArgumentError, "vatio identity: not a Vatio sign-in code" unless code.match?(SIGN_IN_CODE)

        token = token_for(subject: subject, claims: claims, expires_in: expires_in)
        "#{SIGN_IN_HOST}/connect/#{code}?token=#{token}"
      end

      private

      def stringify(claims)
        Hash(claims).each_with_object({}) { |(k, v), out| out[k.to_s] = v }
      end

      def escape(value)
        value.to_s.gsub("&", "&amp;").gsub('"', "&quot;").gsub("<", "&lt;").gsub(">", "&gt;")
      end
    end
  end
end

require_relative "identity/railtie" if defined?(Rails::Railtie)
