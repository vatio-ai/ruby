# frozen_string_literal: true

require "openssl"

module Vatio
  module Identity
    # Everything the signer needs, and nothing that could be guessed wrong.
    #
    # `audience` is the workspace slug, always. Vatio requires `aud` and checks
    # it against the slug, so a token signed for the wrong audience is not a
    # subtly weaker token -- it is rejected outright and the visitor comes
    # through anonymous.
    class Config
      # An EC key names its own algorithm: the curve fixes the hash size, so
      # there is exactly one right answer and asking for it would only be a
      # chance to get it wrong. RSA does not -- RS* and PS* share a key -- so
      # RS256 is the default. Mirrors the table the manifest validates against.
      CURVE_ALGORITHMS = {
        "prime256v1" => "ES256",
        "secp256r1" => "ES256",
        "secp384r1" => "ES384",
        "secp521r1" => "ES512"
      }.freeze
      RSA_DEFAULT = "RS256"

      # Long enough that a visitor is not signed out mid-conversation, short
      # enough that a token scraped from a page stops working the same morning.
      # The web refreshes it on every page load anyway.
      DEFAULT_EXPIRES_IN = 3600

      attr_accessor :audience
      attr_writer :algorithm, :expires_in

      def initialize
        @expires_in = DEFAULT_EXPIRES_IN
      end

      # The PEM, not a path. Read it from an env var or Rails credentials --
      # a private key checked into the repo is a private key that leaked.
      def private_key=(pem)
        @private_key = load_key(pem, "private_key")
        return if @private_key.nil? || @private_key.private?

        raise ConfigurationError,
          "vatio identity: private_key is a PUBLIC key -- it cannot sign. " \
          "Point it at identity.pem, not identity.pub"
      end

      # Optional. Only needed to verify tokens coming back into your own API
      # from a private tool; if unset, the private key verifies its own
      # signatures, which is the same check.
      def public_key=(pem)
        @public_key = load_key(pem, "public_key")
      end

      def private_key
        @private_key || raise(ConfigurationError, missing("private_key"))
      end

      def public_key
        @public_key || private_key
      end

      def expires_in = Integer(@expires_in)

      def audience!
        value = audience.to_s.strip
        return value unless value.empty?

        raise ConfigurationError, missing("audience (your Vatio workspace slug)")
      end

      # Inferred from the key unless pinned. Whatever it ends up being has to
      # equal `auth.algorithm` in vatio.yml, and it is never read from the
      # token's own header on either side: that header is attacker-controlled,
      # and believing it is exactly the algorithm-confusion bug.
      def algorithm
        return @algorithm.to_s if @algorithm

        key = @private_key || @public_key
        raise ConfigurationError, missing("private_key") if key.nil?

        case key
        when OpenSSL::PKey::EC
          curve = key.group.curve_name.to_s
          CURVE_ALGORITHMS.fetch(curve) do
            raise ConfigurationError,
              "vatio identity: curve #{curve.inspect} has no matching JWT algorithm; set config.algorithm"
          end
        when OpenSSL::PKey::RSA then RSA_DEFAULT
        else
          raise ConfigurationError,
            "vatio identity: #{key.class} keys cannot sign a Vatio token; use RSA or EC"
        end
      end

      private

      def load_key(pem, name)
        value = pem.to_s.strip
        return nil if value.empty?

        OpenSSL::PKey.read(value)
      rescue OpenSSL::PKey::PKeyError, ArgumentError, TypeError => e
        raise ConfigurationError, "vatio identity: #{name} is not a readable PEM (#{e.class})"
      end

      def missing(name)
        "vatio identity: #{name} is not configured -- see Vatio::Identity.configure"
      end
    end
  end
end
