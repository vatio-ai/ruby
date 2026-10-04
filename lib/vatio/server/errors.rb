# frozen_string_literal: true

module Vatio
  module Server
    # Every refusal from the server API, with the `code` it was sent with.
    #
    # The subclasses are the decisions a caller actually makes: send a
    # template instead (OutsideWindow), leave this person alone (OptedOut,
    # HumanAnswering), fix the request (TemplateError, InvalidRequest), fix
    # the key (Unauthorized), or try again later (RateLimited, Unavailable).
    # Only the last two are worth retrying, and `retryable?` says so.
    class Error < StandardError
      attr_reader :code, :status, :details, :request_id

      # `headers` is the response's, for the subclasses that read one.
      def initialize(message = nil, code: nil, status: nil, details: {}, request_id: nil, headers: nil)
        super(message || code || "vatio server error")
        @code = code&.to_s
        @status = status
        @details = details || {}
        @request_id = request_id
      end

      def retryable? = false

      # The class a refusal maps to: by code first, since the code is the
      # contract, and by status for codes this version does not know yet.
      def self.class_for(status, code)
        case code.to_s
        when "outside_window" then OutsideWindow
        when "opted_out" then OptedOut
        when "human_takeover", "handoff_pending" then HumanAnswering
        when /\Atemplate_/ then TemplateError
        when "rate_limited" then RateLimited
        when "invalid_key", "workspace_forbidden" then Unauthorized
        when "not_found" then NotFound
        else
          case status.to_i
          when 401, 403 then Unauthorized
          when 404 then NotFound
          when 409 then Conflict
          when 400, 422 then InvalidRequest
          when 429 then RateLimited
          when 408, 500..599 then Unavailable
          else Error
          end
        end
      end

      # From a response the API answered with: `{error: {code, message,
      # ...details}, request_id}`. A body that is not that -- a proxy's HTML
      # 502 -- still becomes an error of the right class, by its status.
      def self.from_response(status, body, headers = {})
        payload = body.is_a?(Hash) ? body : {}
        error = payload["error"].is_a?(Hash) ? payload["error"] : {}
        code = error["code"] || "http_#{status}"
        message = error["message"] || "Vatio answered HTTP #{status}"
        details = error.reject { |key, _| %w[code message].include?(key) }

        class_for(status, code).new(
          message, code: code, status: status, details: details,
          request_id: payload["request_id"] || headers["x-request-id"], headers: headers
        )
      end
    end

    # The contact has not written in the last 24 hours, so WhatsApp only
    # delivers an approved template, and none was sent. Only you can decide
    # whether a template is the right thing to send instead.
    class OutsideWindow < Error
      def last_inbound_at
        value = details["last_inbound_at"]
        value && Time.iso8601(value.to_s)
      rescue ArgumentError
        nil
      end
    end

    # The contact asked not to be written to from this number.
    OptedOut = Class.new(Error)

    # A person is answering this conversation from the inbox
    # (`human_takeover`), or it is waiting for one (`handoff_pending`).
    # Writing over them is exactly what this refusal is for.
    HumanAnswering = Class.new(Error)

    # The template cannot be sent as given: not found (often created in Meta a
    # minute ago -- Vatio is syncing, retry shortly), not approved, or the
    # wrong number of params.
    TemplateError = Class.new(Error)

    # Any other 422: an invalid number, no `brief` or `text`, an identity
    # that does not verify, a preview key writing to a number that is not a
    # test phone.
    InvalidRequest = Class.new(Error)

    # The key is missing, wrong, revoked, or belongs to another workspace.
    Unauthorized = Class.new(Error)

    # A message id this key's workspace and environment do not have.
    NotFound = Class.new(Error)

    # Any other 409: the idempotency key was already used for a different
    # message (`details["message_id"]` names it), the conversation is
    # signed in as someone else, or the WhatsApp number is not connected or
    # not live.
    Conflict = Class.new(Error)

    # More than 60 messages a minute on one key.
    class RateLimited < Error
      attr_reader :retry_after

      # Seconds, when Vatio says; nil when it does not.
      def initialize(message = nil, headers: nil, **options)
        super
        @retry_after = Integer((headers || {})["retry-after"].to_s, exception: false)
      end

      def retryable? = true
    end

    # Vatio did not answer, or answered 5xx: a timeout, a refused connection,
    # a deploy. Retry with the same idempotency key and a request that did
    # get through is answered with the message it made, not a second one.
    class Unavailable < Error
      def retryable? = true
    end
  end
end
