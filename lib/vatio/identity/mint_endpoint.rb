# frozen_string_literal: true

require "json"
require "openssl"
require "digest"
require "jwt"

module Vatio
  module Identity
    # The endpoint Vatio posts to for a channel that carries no session.
    #
    # WhatsApp proves someone holds a handset, Instagram that someone holds an
    # account, and nothing more. Whether either belongs to a customer is a fact
    # only your database knows, so Vatio asks -- and the answer comes back
    # signed rather than asserted.
    #
    #   POST /api/vatio/identity
    #   X-Api-Key: <the secret you set with `vatio secrets set`>
    #   { "channel": "whatsapp", "phone_number": "+56912345678" }
    #   { "channel": "instagram", "instagram_id": "17841...", "username": "ana.perez" }
    #   -> 200 { "token": "<jwt>" }   anything else -> anonymous visitor
    #
    # The request and response shapes are fixed by Vatio, not declared, so
    # there is nothing here to configure except who you recognize.
    class MintEndpoint
      # Vatio only asks about channels that carry a verified identifier of
      # their own. Anything else arriving here did not come from Vatio.
      CHANNELS = %w[whatsapp instagram].freeze

      # Evidence a resolver may leave undeclared. Vatio omits `username` when
      # Meta did not answer, so a resolver that matches on the IGSID alone
      # has no reason to name it.
      OPTIONAL = { "instagram" => %i[username] }.freeze

      # A phone number is long enough that a body limit this generous still
      # rules out anyone using the endpoint as a parser.
      MAX_BODY = 4096

      # Pinned rather than read from the token's own header, which is written
      # by whoever sent the request.
      SIGNATURE_HEADER = "HTTP_VATIO_SIGNATURE"
      SIGNATURE_ALGORITHM = "ES256"
      SIGNATURE_ISSUER = "vatio.ai"
      SIGNATURE_CLAIMS = %w[iss aud exp body_sha256].freeze
      # Clock drift only; Vatio already expires the signature after 60 seconds.
      SIGNATURE_LEEWAY = 30

      def initialize(&resolver)
        unless resolver
          raise ArgumentError,
            "Vatio::Identity.mint needs a block: given a channel and what it proved (a phone number, an Instagram account), return " \
            "{ subject:, claims: } for the user it belongs to, or nil for a stranger"
        end

        @resolver = resolver
      end

      def call(env)
        return deny unless env["REQUEST_METHOD"] == "POST"
        return deny unless authorized?(env)

        # Read once: the signature covers these exact bytes.
        body = read_body(env)
        return deny if body.nil?
        return deny unless signed_by_vatio?(env, body)

        evidence = parse(body)
        return deny unless evidence

        arguments = arguments_for(evidence)
        return deny if arguments.nil?

        found = @resolver.call(**arguments)
        return deny if found.nil?

        ok(token_for(found))
      rescue ConfigurationError
        # Misconfiguration is the operator's problem, not the visitor's, and it
        # must not read as "we do not know this number".
        raise
      end

      private

      # Constant time, and against a key that Config has already refused to let
      # be blank. Both halves matter: a fast `==` leaks the secret a byte at a
      # time to anyone patient, and an absent secret makes the comparison moot.
      def authorized?(env)
        expected = Identity.config.mint_api_key!
        header = "HTTP_#{Identity.config.mint_header.to_s.upcase.tr("-", "_")}"
        given = env[header].to_s
        return false if given.empty?

        OpenSSL.secure_compare(given, expected)
      end

      # Not optional: mint_public_key! raises rather than letting an unsigned
      # request through, which is a fallback an attacker would simply take.
      def signed_by_vatio?(env, body)
        key = Identity.config.mint_public_key!

        raw = env[SIGNATURE_HEADER].to_s
        return false if raw.empty?

        claims, = JWT.decode(
          raw, key, true,
          algorithms: [ SIGNATURE_ALGORITHM ],
          required_claims: SIGNATURE_CLAIMS.dup,
          verify_expiration: true,
          leeway: SIGNATURE_LEEWAY,
          # The audience is this workspace's slug, so a signature captured for
          # one workspace cannot be replayed at another.
          aud: Identity.config.audience!,
          verify_aud: true
        )

        return false unless claims["iss"] == SIGNATURE_ISSUER

        # Binds the signature to this phone number, not to any question for the
        # next minute.
        expected = Digest::SHA256.hexdigest(body)
        OpenSSL.secure_compare(claims["body_sha256"].to_s, expected)
      rescue JWT::DecodeError
        false
      end

      def read_body(env)
        input = env["rack.input"]
        return nil unless input

        body = input.read(MAX_BODY + 1).to_s
        return nil if body.bytesize > MAX_BODY

        body
      end

      def parse(body)
        payload = JSON.parse(body)
        return nil unless payload.is_a?(Hash)

        channel = payload["channel"].to_s
        return nil unless CHANNELS.include?(channel)

        # Exact, as Vatio sent it. No normalizing, no `LIKE`, no stripping the
        # country code to find a match: a loose comparison here is a lookup
        # that can be steered into returning somebody else's account.
        case channel
        when "whatsapp"
          phone = payload["phone_number"].to_s.strip
          return nil if phone.empty?

          { channel: channel, phone_number: phone }
        when "instagram"
          instagram_id = payload["instagram_id"].to_s.strip
          return nil if instagram_id.empty?

          username = payload["username"].to_s.strip.delete_prefix("@")
          { channel: channel, instagram_id: instagram_id, username: username.empty? ? nil : username }
        end
      rescue JSON::ParserError
        nil
      end

      # Only the keywords the block declares. A resolver written for WhatsApp
      # alone (`|channel:, phone_number:|`) answers "stranger" to Instagram
      # instead of raising ArgumentError on every request from that channel.
      def arguments_for(evidence)
        params = @resolver.parameters
        named = params.filter_map { |type, name| name if %i[key keyreq].include?(type) }
        return evidence if named.empty?

        keyrest = params.any? { |type, _| type == :keyrest }
        arguments = keyrest ? evidence : evidence.select { |key, _| named.include?(key) }

        dropped = evidence.keys - arguments.keys
        return nil unless (dropped - OPTIONAL.fetch(evidence[:channel], [])).empty?

        required = params.filter_map { |type, name| name if type == :keyreq }
        return nil unless (required - evidence.keys).empty?

        arguments
      end

      def token_for(found)
        found = { subject: found } unless found.is_a?(Hash)
        Identity.token_for(
          subject: found[:subject] || found["subject"],
          claims: found[:claims] || found["claims"] || {}
        )
      end

      def ok(token)
        body = JSON.generate({ "token" => token })
        [ 200, { "content-type" => "application/json", "cache-control" => "no-store" }, [ body ] ]
      end

      # One response for every refusal, with no reason in it. Vatio treats any
      # non-2xx identically, and the difference between "bad key", "unknown
      # number" and "malformed" is only ever useful to somebody probing.
      def deny
        [ 404, { "content-type" => "application/json", "cache-control" => "no-store" }, [ "{}" ] ]
      end
    end
  end
end
