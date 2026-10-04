# frozen_string_literal: true

module Vatio
  module Server
    # A controller that receives Vatio's webhooks: it checks the signature
    # on the raw body, answers 400 to anything that does not verify, and
    # hands each verified event to the handler for its type.
    #
    #   # config/routes.rb
    #   post "/webhooks/vatio", to: "vatio_webhooks#create"
    #
    #   class VatioWebhooksController < ActionController::API
    #     include Vatio::Server::WebhookReceiver
    #
    #     on_vatio_event "message.replied" do |event|
    #       message = Vatio::Server::Message.from(event["data"]["message"])
    #       Order.find_by(vatio_ref: message.external_ref)&.touch(:customer_answered_at)
    #     end
    #   end
    #
    # The secret is `Vatio::Server.config.webhook_secret` unless the
    # controller defines `vatio_webhook_secret`. Override
    # `handle_vatio_event(event)` instead of the macro to see every event.
    #
    # Vatio delivers at least once, so the same event can arrive twice:
    # dedupe on `event["id"]`, which is the same on every retry. A handler
    # that raises answers 500 and the delivery is retried later, which is
    # what you want when your database was down, and why a handler should
    # be safe to run twice.
    module WebhookReceiver
      def self.included(base)
        base.extend(ClassMethods)
        # Vatio has no session and no CSRF token: the signature is what
        # authenticates this request.
        base.skip_forgery_protection if base.respond_to?(:skip_forgery_protection)
      end

      module ClassMethods
        # One or more event types -- message.sent, message.failed,
        # message.delivered, message.read, message.delivery_failed,
        # message.replied, ping. The block runs on the controller instance.
        def on_vatio_event(*types, &handler)
          raise ArgumentError, "vatio server: on_vatio_event needs a block" unless handler

          own = (@vatio_event_handlers ||= {})
          types.flatten.each { |type| (own[type.to_s] ||= []) << handler }
        end

        # Inherited handlers first, then this class's own.
        def vatio_event_handlers
          inherited = superclass.respond_to?(:vatio_event_handlers) ? superclass.vatio_event_handlers : {}
          inherited.merge(@vatio_event_handlers || {}) { |_type, parent, child| parent + child }
        end
      end

      def create
        event = Webhook.verify!(
          payload: request.raw_post,
          signature: request.headers[Webhook::HEADER],
          secret: vatio_webhook_secret,
          tolerance: vatio_webhook_tolerance
        )
      rescue Webhook::InvalidSignature => e
        logger&.warn("[Vatio::Server::WebhookReceiver] refused: #{e.message}")
        head :bad_request
      else
        handle_vatio_event(event)
        head :ok unless performed?
      end

      private

      def handle_vatio_event(event)
        self.class.vatio_event_handlers.fetch(event["type"].to_s, []).each do |handler|
          instance_exec(event, &handler)
        end
      end

      def vatio_webhook_secret
        Server.config.webhook_secret
      end

      def vatio_webhook_tolerance
        Webhook::TOLERANCE
      end
    end
  end
end
