# frozen_string_literal: true

require "uri"

module Vatio
  module Server
    # The server API, one method per endpoint. `Vatio::Server.send_message`
    # and friends use one built from `Vatio::Server.config`; build your own
    # for a second key:
    #
    #   staging = Vatio::Server::Client.new(server_key: ENV["VATIO_PREVIEW_KEY"], workspace: "acme")
    class Client
      API_PATH = "/api/server/v1"

      attr_reader :config

      def initialize(config = nil, transport: nil, **options)
        @config = config || Config.new(**options)
        @transport = transport
      end

      # Has the agent write to `to` first. Returns a Message, `queued`: it
      # is recorded and on its way, and the send itself happens a moment
      # later -- read it back with `message_status` or hear about it on your
      # webhook.
      #
      # brief:    what the agent should write about, and the facts to use.
      # text:     your own words, sent as is.
      # template: { name:, language:, params: [] }, used only when the 24-hour
      #           window is closed -- send it too to always reach the person.
      #
      # idempotency_key defaults to external_ref. Same key, same request:
      # Vatio answers with the message the first one made and sends nothing
      # (`replayed?`). Same key, different request: Conflict. So give each
      # message its own ref -- "order-1042-shipped", not "order-1042".
      #
      # subject: signs an identity for that user (aud: the workspace, exp:
      # now + identity_ttl), so a private tool can run when they answer. The
      # exp has to cover how long they may take to: past it, they are
      # answered as a stranger. Or pass a token you signed as `identity:`.
      def send_message(to:, brief: nil, text: nil, template: nil, external_ref: nil, idempotency_key: nil,
                       subject: nil, claims: {}, identity_ttl: IDENTITY_TTL, identity: nil)
        raise ArgumentError, "vatio server: pass subject: or identity:, not both" if subject && identity

        identity ||= identity_for(subject: subject, claims: claims, ttl: identity_ttl) if subject
        key = present(idempotency_key) || present(external_ref)
        body = {
          to: to.to_s,
          brief: brief,
          text: text,
          template: template && normalize_template(template),
          external_ref: external_ref,
          identity: identity
        }.compact

        response = request(:post, "messages", body: body, headers: key ? { "Idempotency-Key" => key } : {})
        Message.from(response.body, replayed: response.headers["idempotent-replayed"] == "true")
      end

      def message_status(id)
        Message.from(request(:get, "messages/#{escape(id)}").body)
      end

      # Newest first, up to 50 a page. `status` is queued, sent or failed;
      # `external_ref` finds the messages for one of your own records.
      def messages(external_ref: nil, status: nil, limit: nil, before: nil)
        query = { external_ref: external_ref, status: status, limit: limit, before: before }.compact
        MessageList.from(request(:get, "messages", query: query).body)
      end

      def templates
        Array(request(:get, "templates").body["templates"]).map { |item| Template.from(item) }
      end

      # The identity token a message carries, signed with Vatio::Identity's
      # key for this client's workspace. Sign once and pass it as
      # `identity:` if you retry a call yourself: a token signed again is a
      # different request to the idempotency check, and answers Conflict.
      def identity_for(subject:, claims: {}, ttl: IDENTITY_TTL)
        Identity.token_for(subject: subject, claims: claims, expires_in: ttl.to_i, audience: config.workspace!)
      end

      private

      def transport
        @transport || Server.transport
      end

      def request(method, path, query: nil, body: nil, headers: {})
        url = "#{config.base_url!}#{API_PATH}/#{escape(config.workspace!)}/#{path}"
        url += "?#{URI.encode_www_form(query)}" if query && !query.empty?

        response = transport.call(
          method: method,
          url: url,
          headers: {
            "Authorization" => "Bearer #{config.server_key!}",
            "Accept" => "application/json",
            "Content-Type" => "application/json",
            "User-Agent" => "vatio-identity-ruby/#{Identity::VERSION}"
          }.merge(headers),
          body: body && JSON.generate(body),
          open_timeout: config.open_timeout,
          read_timeout: config.read_timeout
        )

        parsed = parse(response.body)
        raise Error.from_response(response.status, parsed, response.headers) unless (200..299).cover?(response.status)

        unless parsed.is_a?(Hash)
          raise Unavailable.new("vatio server: HTTP #{response.status} with a body that is not JSON",
            code: "invalid_response", status: response.status, request_id: response.headers["x-request-id"])
        end

        Response.new(status: response.status, headers: response.headers, body: parsed)
      end

      def parse(body)
        return nil if body.nil? || body.empty?

        JSON.parse(body)
      rescue JSON::ParserError
        nil
      end

      # Accepts a Hash with symbol or string keys, or anything with `to_h`.
      def normalize_template(template)
        hash = template.to_h.transform_keys(&:to_s)
        { name: hash["name"], language: hash["language"], params: Array(hash["params"]).map(&:to_s) }
      end

      def present(value)
        value = value.to_s.strip
        value.empty? ? nil : value
      end

      def escape(value) = URI.encode_www_form_component(value.to_s)
    end
  end
end
