# frozen_string_literal: true

module Vatio
  module Server
    # Shared by the values below: the API's JSON, read into a frozen struct.
    # Keys this version does not know are dropped rather than refused, so a
    # field Vatio adds tomorrow does not break today's gem.
    module Value
      module_function

      def time(value)
        value && Time.iso8601(value.to_s)
      rescue ArgumentError
        nil
      end

      def build(klass, hash, **extra)
        hash = (hash || {}).transform_keys(&:to_s)
        attrs = klass.members.to_h { |name| [ name, hash[name.to_s] ] }
        klass.new(**attrs, **extra).freeze
      end
    end

    # A message your backend sent, as Vatio reports it -- the same shape on
    # the response, on `message_status`, and in every webhook's
    # `data["message"]`:
    #
    #   Vatio::Server::Message.from(event["data"]["message"])
    #
    # `status` is the message's own state: queued (recorded, not sent yet),
    # sent, or failed (with `error["code"]`). `content` is what reached the
    # phone -- the agent's words, your text as sent, or the template rendered
    # -- and `chat_message_id` its row in the conversation, once it is sent.
    # `delivery` is Meta's word on it -- sent, delivered, read or failed --
    # once there is one. Nested hashes (`template`, `delivery`, `error`) keep
    # the API's string keys.
    Message = Struct.new(
      :id, :status, :mode, :channel, :environment, :to, :chat_id, :external_ref, :idempotency_key,
      :brief, :text, :template, :content, :chat_message_id, :delivery, :error, :sent_at, :replied_at,
      :created_at, :replayed,
      keyword_init: true
    ) do
      def self.from(hash, replayed: false)
        hash = (hash || {}).transform_keys(&:to_s)
        times = %w[sent_at replied_at created_at].to_h { |key| [ key, Value.time(hash[key]) ] }
        Value.build(self, hash.merge(times).except("replayed"), replayed: replayed)
      end

      # True when the request reused an idempotency key: this is the message
      # the first request made, as it stands now, and nothing new was sent.
      def replayed? = replayed == true

      def queued? = status == "queued"
      def sent? = status == "sent"
      def failed? = status == "failed"
      def replied? = !replied_at.nil?

      def error_code = error && error["code"]
    end

    # One page of `messages`, newest first. Pass `next_before` back as
    # `before:` for the next one; it is nil on the last page.
    MessageList = Struct.new(:messages, :next_before, keyword_init: true) do
      include Enumerable

      def self.from(hash)
        hash = (hash || {}).transform_keys(&:to_s)
        new(
          messages: Array(hash["messages"]).map { |item| Message.from(item) }.freeze,
          next_before: hash["next_before"]
        ).freeze
      end

      def each(&block) = messages.each(&block)
      def next_page? = !next_before.nil?

      # The page's messages, not the struct's members, which is what Struct
      # would answer for these ahead of Enumerable.
      def to_a = messages.dup
      alias_method :entries, :to_a
      def size = messages.size
      alias_method :length, :size
    end
  end
end
