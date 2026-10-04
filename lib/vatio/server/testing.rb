# frozen_string_literal: true

require "jwt"
require "uri"

require_relative "../server"

module Vatio
  module Server
    # For your own test suite: no network, no key, and a record of what your
    # code asked Vatio to send.
    #
    #   require "vatio/server/testing"
    #
    #   setup { Vatio::Server::Testing.fake! }
    #   teardown { Vatio::Server::Testing.real! }
    #
    #   Order.ship!(order)
    #   sent = Vatio::Server::Testing.messages.last
    #   assert_equal "+56912345678", sent.to
    #   assert_equal "order-1042-shipped", sent.external_ref
    #
    #   Vatio::Server::Testing.fail_next!(:outside_window)
    #   assert_raises(Vatio::Server::OutsideWindow) { Order.remind!(order) }
    #
    # The fake answers as the API does -- 202 and a queued message, 200 and
    # the same message for an idempotency key it has seen, Conflict for one
    # reused with a different request -- through the same parsing and error
    # mapping as a real response, so what your code rescues is what it will
    # rescue in production. It assumes the 24-hour window is open; set
    # `window_open = false` and a message without a template raises
    # OutsideWindow, as it would.
    module Testing
      # A request to send, as the fake received it. `subject` and `claims`
      # are read back out of the identity token, unverified.
      Recorded = Struct.new(
        :id, :to, :brief, :text, :template, :external_ref, :idempotency_key, :identity, :subject, :claims, :mode,
        keyword_init: true
      )

      # Status and code for the refusals `fail_next!` knows by name. Any
      # other code is a 422, unless you pass `status:`.
      FAILURES = {
        "outside_window" => 422, "opted_out" => 409, "human_takeover" => 409, "handoff_pending" => 409,
        "template_required" => 422, "template_not_found" => 422, "template_not_approved" => 422,
        "template_params" => 422, "content_required" => 422, "brief_too_long" => 422, "text_too_long" => 422,
        "invalid_recipient" => 422, "not_a_test_phone" => 422, "identity_not_configured" => 422,
        "invalid_identity" => 422, "whatsapp_not_connected" => 409, "whatsapp_paused" => 409,
        "idempotency_conflict" => 409, "identity_conflict" => 409, "invalid_key" => 401,
        "workspace_forbidden" => 403, "not_found" => 404, "rate_limited" => 429, "unavailable" => 503
      }.freeze

      # `fail_next!(:timeout)` and `fail_next!(:network_error)` raise in the
      # transport, as a socket would, rather than answering at all.
      NETWORK_FAILURES = %w[timeout network_error].freeze

      class << self
        attr_writer :templates, :window_open

        # Swaps the transport for the in-memory one, and fills a key and a
        # workspace if the suite has none, so no test needs a real `vsk_`.
        # With a block, puts everything back afterwards.
        def fake!
          unless faking?
            @previous = { transport: Server.instance_variable_get(:@transport),
                          server_key: Server.config.server_key,
                          workspace: Server.config.instance_variable_get(:@workspace) }
            Server.config.server_key = "vsk_test_fake" if Server.config.server_key.to_s.strip.empty?
            Server.config.workspace = "test" if Server.config.workspace.nil?
            Server.transport = FakeTransport.new
          end
          reset!
          return self unless block_given?

          begin
            yield
          ensure
            real!
          end
        end

        def real!
          return unless faking?

          Server.transport = @previous[:transport]
          Server.config.server_key = @previous[:server_key]
          Server.config.workspace = @previous[:workspace]
          @previous = nil
        end

        def faking? = Server.instance_variable_get(:@transport).is_a?(FakeTransport)

        # Forgets what was sent and any pending failure; templates and the
        # window go back to their defaults.
        def reset!
          @templates = []
          @window_open = true
          fake.reset! if faking?
        end

        # Each message the fake created, oldest first. A replay of an
        # idempotency key creates none, as it would not on Vatio.
        def messages = faking? ? fake.messages : []

        # Every request, reads included: [method, path, body].
        def requests = faking? ? fake.requests : []

        # The next call answers with this refusal instead -- any call, so
        # `fail_next!(:not_found)` before `message_status` works too.
        def fail_next!(code, status: nil, message: nil, **details)
          code = code.to_s
          fake.fail_next = { code: code, status: status || FAILURES.fetch(code, 422),
                             message: message || "#{code} (Vatio::Server::Testing)", details: details }
        end

        # What `Vatio::Server.templates` answers: Hashes as the API sends
        # them, or Templates.
        def templates = @templates || []

        def window_open? = @window_open != false

        # A webhook request as Vatio would deliver it, for testing your
        # receiver: post `body` with `headers` to its route.
        #
        #   hook = Vatio::Server::Testing.webhook("message.replied", message: { id: 1, external_ref: "x" })
        #   post "/webhooks/vatio", params: hook.body, headers: hook.headers
        #
        # `data` as a Hash, or its keys as keywords, as above.
        def webhook(type, data = {}, secret: Server.config.webhook_secret, id: "evt_#{rand(1_000_000)}", at: Time.now,
                    **fields)
          event = { id: id, type: type, created_at: at.utc.iso8601, workspace: Server.config.workspace,
                    environment: "live", data: data.to_h.merge(fields) }
          body = JSON.generate(event)
          WebhookRequest.new(
            body: body,
            headers: { Webhook::HEADER => Webhook.sign(payload: body, secret: secret, at: at), "Content-Type" => "application/json" },
            event: JSON.parse(body)
          )
        end

        private

        def fake
          Server.instance_variable_get(:@transport)
        end
      end

      # What `webhook` builds: the body to post, its headers, and the event
      # your handler should receive.
      WebhookRequest = Struct.new(:body, :headers, :event, keyword_init: true)

      # The transport the fake installs: the same `call` as the real one,
      # answered from memory.
      class FakeTransport
        attr_accessor :fail_next
        attr_reader :messages, :requests

        def initialize
          @lock = Mutex.new
          reset!
        end

        def reset!
          @lock.synchronize do
            @messages = []
            @payloads = {}
            @by_key = {}
            @requests = []
            @fail_next = nil
            @next_id = 0
          end
        end

        def call(method:, url:, headers: {}, body: nil, **)
          uri = URI.parse(url)
          path = uri.path.sub(%r{\A#{Client::API_PATH}/[^/]+/}o, "")
          query = URI.decode_www_form(uri.query.to_s).to_h
          params = body ? JSON.parse(body) : {}

          @lock.synchronize do
            @requests << [ method.to_s.upcase, path, params ]
            failure = @fail_next
            @fail_next = nil
            return answer_failure(failure) if failure

            route(method.to_s.downcase, path, query, params, headers)
          end
        end

        private

        def route(method, path, query, params, headers)
          shown = method == "get" && path[%r{\Amessages/(\d+)\z}, 1]
          if method == "post" && path == "messages" then create(params, headers["Idempotency-Key"])
          elsif method == "get" && path == "messages" then list(query)
          elsif method == "get" && path == "templates" then json(200, { templates: Testing.templates.map(&:to_h) })
          elsif shown && @payloads[shown.to_i] then json(200, @payloads[shown.to_i])
          elsif shown then refusal(404, "not_found", "Resource not found")
          else refusal(404, "not_found", "No such endpoint in Vatio::Server::Testing: #{method.upcase} #{path}")
          end
        end

        def create(params, key)
          if key && (previous = @by_key[key])
            return json(200, @payloads[previous[:id]], "idempotent-replayed" => "true") if previous[:params] == params

            return refusal(409, "idempotency_conflict",
              "Idempotency-Key #{key.inspect} was already used for a different message (#{previous[:id]}).",
              message_id: previous[:id])
          end

          to = params["to"].to_s
          return refusal(422, "invalid_recipient", "to must be a phone number in international format.") if to.gsub(/\D/, "").length < 8
          if params["brief"].to_s.strip.empty? && params["text"].to_s.strip.empty?
            return refusal(422, "content_required", "Send `text` or `brief`.")
          end

          mode = if Testing.window_open? then params["text"] ? "text" : "agent"
          elsif params["template"] then "template"
          end
          unless mode
            return refusal(422, "outside_window", "The contact has not written in the last 24 hours.",
              last_inbound_at: nil)
          end

          claims = claims_of(params["identity"])
          template = params["template"]&.slice("name", "language", "params")
          text = (params["text"] if mode == "text")
          template = (template if mode == "template")

          id = (@next_id += 1)
          payload = {
            id: id, status: "queued", mode: mode, channel: "whatsapp", environment: "live",
            to: "+#{to.gsub(/\D/, "")}", chat_id: id, external_ref: params["external_ref"], idempotency_key: key,
            brief: params["brief"], text: text, template: template, content: nil, chat_message_id: nil,
            delivery: nil, error: nil, sent_at: nil, replied_at: nil, created_at: Time.now.utc.iso8601
          }
          @payloads[id] = JSON.parse(JSON.generate(payload))
          @by_key[key] = { id: id, params: params } if key
          @messages << Recorded.new(
            id: id, to: params["to"], brief: params["brief"], text: params["text"], template: params["template"],
            external_ref: params["external_ref"], idempotency_key: key, identity: params["identity"],
            subject: claims["sub"], claims: claims.reject { |name, _| Identity::REGISTERED_CLAIMS.include?(name) },
            mode: mode
          ).freeze
          json(202, payload)
        end

        def list(query)
          items = @payloads.values.reverse
          items = items.select { |item| item["external_ref"] == query["external_ref"] } if query["external_ref"]
          items = items.select { |item| item["status"] == query["status"] } if query["status"]
          items = items.select { |item| item["id"] < query["before"].to_i } if query["before"]
          limit = (query["limit"] || 50).to_i.clamp(1, 50)
          page = items.first(limit)
          json(200, { messages: page, next_before: (page.last["id"] if page.size == limit && !page.empty?) })
        end

        def answer_failure(failure)
          if NETWORK_FAILURES.include?(failure[:code])
            raise Unavailable.new("vatio server: #{failure[:message]}", code: failure[:code])
          end

          refusal(failure[:status], failure[:code], failure[:message], **failure[:details])
        end

        def claims_of(token)
          return {} if token.to_s.empty?

          JWT.decode(token, nil, false).first
        rescue JWT::DecodeError
          {}
        end

        def refusal(status, code, message, **details)
          json(status, { error: { code: code, message: message, **details }, request_id: "req_test" },
            "x-request-id" => "req_test")
        end

        def json(status, body, headers = {})
          Response.new(status: status, headers: { "content-type" => "application/json" }.merge(headers),
            body: JSON.generate(body))
        end
      end
    end
  end
end

if defined?(RSpec::Matchers)
  # expect { Order.ship!(order) }.to have_sent_message(to: "+56912345678", external_ref: "order-1042-shipped")
  # expect(Vatio::Server::Testing).to have_sent_message(to: "+56912345678")
  #
  # Every attribute but `to` is compared as given, RSpec matchers included
  # (`brief: a_string_including("1042")`); `to` is compared by its digits,
  # so "+56 9 1234 5678" matches "+56912345678".
  RSpec::Matchers.define :have_sent_message do |to: nil, **expected|
    supports_block_expectations

    match do |actual|
      before = Vatio::Server::Testing.messages.size
      actual.call if actual.is_a?(Proc)
      candidates = actual.is_a?(Proc) ? Vatio::Server::Testing.messages.drop(before) : Vatio::Server::Testing.messages

      @found = candidates.select do |message|
        (to.nil? || message.to.to_s.gsub(/\D/, "") == to.to_s.gsub(/\D/, "")) &&
          expected.all? { |name, value| values_match?(value, message.public_send(name)) }
      end
      @candidates = candidates
      !@found.empty?
    end

    failure_message do
      wanted = { to: to, **expected }.compact
      sent = @candidates.map { |message| message.to_h.slice(:to, *expected.keys) }
      "expected a message matching #{wanted.inspect}, but #{sent.empty? ? "none was sent" : "sent: #{sent.inspect}"}"
    end

    failure_message_when_negated do
      "expected no message matching #{{ to: to, **expected }.compact.inspect}, but #{@found.size} were sent"
    end
  end
end
