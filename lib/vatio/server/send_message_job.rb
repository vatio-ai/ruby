# frozen_string_literal: true

require "active_job"
require "securerandom"

module Vatio
  module Server
    # `Vatio::Server.send_message` on your queue, with the same keywords:
    #
    #   Vatio::Server::SendMessageJob.perform_later(
    #     to: order.phone, brief: "Order #{order.number} shipped...",
    #     external_ref: "order-#{order.id}-shipped", subject: order.user_id
    #   )
    #
    # Retried when Vatio is rate limiting or unreachable, never when it said
    # no: a closed window or an opted-out contact is the same answer on the
    # tenth try. Those are logged and discarded; subclass and `discard_on` the
    # one you want to act on -- a later declaration wins:
    #
    #   class ShippedMessageJob < Vatio::Server::SendMessageJob
    #     discard_on(Vatio::Server::OutsideWindow) { |job, error| ... }
    #   end
    #
    # A retry is safe because the request carries an idempotency key: yours,
    # your external_ref, or one made here when the job is enqueued. And an
    # identity for `subject:` is signed here too, once, rather than on every
    # attempt -- a token signed again is a different request to the
    # idempotency check, which would answer Conflict instead of the message
    # the first attempt made. That token sits in your queue until the job
    # runs, and its exp starts at enqueue: a job scheduled far ahead needs an
    # identity_ttl that covers the wait too.
    class SendMessageJob < ActiveJob::Base
      queue_as :default

      # Declared first so the retries below, declared later, take precedence.
      discard_on Vatio::Server::Error do |job, error|
        job.logger&.warn(
          "[Vatio::Server::SendMessageJob] not sent: #{error.code} #{error.message} " \
          "(status #{error.status.inspect}, request #{error.request_id.inspect})"
        )
      end

      # About 3s, 18s, 1.5m, 4m, 10m... -- past a rate limit's minute and past
      # most deploys, and then it fails where your queue shows failed jobs.
      retry_on Vatio::Server::RateLimited, Vatio::Server::Unavailable,
        wait: ->(executions) { (executions**4) + 2 }, attempts: 10

      def self.prepare(arguments)
        options = arguments.first
        return arguments unless arguments.size == 1 && options.is_a?(Hash)

        options = options.transform_keys(&:to_sym)
        subject = options.delete(:subject)
        claims = options.delete(:claims) || {}
        ttl = options.delete(:identity_ttl) || IDENTITY_TTL
        options[:identity] ||= Server.identity_for(subject: subject, claims: claims, ttl: ttl) if subject
        options[:idempotency_key] ||= options[:external_ref] || "job-#{SecureRandom.uuid}"

        [ Hash.ruby2_keywords_hash(options) ]
      end

      def initialize(*arguments)
        super(*self.class.prepare(arguments))
      end
      ruby2_keywords(:initialize)

      def perform(**options)
        Server.send_message(**options)
      end
    end
  end
end
