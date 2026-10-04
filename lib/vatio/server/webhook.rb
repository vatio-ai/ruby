# frozen_string_literal: true

require "json"
require "openssl"

module Vatio
  module Server
    # Checks that a webhook came from Vatio, the way it was signed:
    #
    #   Vatio-Signature: t=1696262400,v1=5257a8...
    #
    # `v1` is the hex HMAC-SHA256 of "#{t}.#{raw body}" under the endpoint's
    # `whsec_` secret. The timestamp is inside what is signed, so a captured
    # delivery cannot be replayed later with a fresh `t`, and one older than
    # `tolerance` is refused.
    #
    # The raw body, byte for byte: a body parsed and serialized again is a
    # different string, and its signature does not match. In Rails that is
    # `request.raw_post`, never `params`.
    module Webhook
      HEADER = "Vatio-Signature"
      TOLERANCE = 300

      InvalidSignature = Class.new(StandardError)

      module_function

      # The event, parsed -- `{"id", "type", "created_at", "workspace",
      # "environment", "data"}` -- or InvalidSignature.
      #
      # Vatio delivers at least once: a delivery that timed out on your side
      # is sent again, with the same `event["id"]`. Dedupe on it.
      def verify!(payload:, signature:, secret:, tolerance: TOLERANCE, now: Time.now)
        secret = secret.to_s
        # An empty secret is a key anyone can sign with.
        raise ConfigurationError, "vatio server: the webhook secret is blank -- see Vatio::Server.configure" if secret.strip.empty?

        payload = payload.to_s
        timestamp, digests = parse(signature)
        raise InvalidSignature, "no #{HEADER} header, or not t=...,v1=..." if timestamp.nil? || digests.empty?
        raise InvalidSignature, "#{HEADER} timestamp is outside the tolerance" if (now.to_i - timestamp).abs > tolerance.to_i

        expected = digest(secret, timestamp, payload)
        raise InvalidSignature, "#{HEADER} does not match the body" unless digests.any? { |candidate| secure_compare(candidate, expected) }

        event = JSON.parse(payload)
        raise InvalidSignature, "the body is not a JSON object" unless event.is_a?(Hash)

        event
      rescue JSON::ParserError
        raise InvalidSignature, "the body is not JSON"
      end

      # The header Vatio would send for this body, for your own tests of a
      # receiver. Vatio::Server::Testing.webhook builds a whole request.
      def sign(payload:, secret:, at: Time.now)
        timestamp = at.to_i
        "t=#{timestamp},v1=#{digest(secret.to_s, timestamp, payload.to_s)}"
      end

      def digest(secret, timestamp, payload)
        OpenSSL::HMAC.hexdigest("SHA256", secret, "#{timestamp}.#{payload}")
      end

      # Every `v1` is a candidate: a header may one day carry two, while a
      # secret is being rotated.
      def parse(header)
        timestamp = nil
        digests = []
        header.to_s.split(",").each do |part|
          name, value = part.strip.split("=", 2)
          case name
          when "t" then timestamp = Integer(value.to_s, exception: false)
          when "v1" then digests << value.to_s
          end
        end
        [ timestamp, digests ]
      end

      def secure_compare(left, right)
        left.bytesize == right.bytesize && OpenSSL.fixed_length_secure_compare(left, right)
      end
    end
  end
end
