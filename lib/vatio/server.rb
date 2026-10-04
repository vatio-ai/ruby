# frozen_string_literal: true

require "json"
require "time"

require_relative "identity"
require_relative "server/config"
require_relative "server/errors"
require_relative "server/message"
require_relative "server/template"
require_relative "server/transport"
require_relative "server/client"
require_relative "server/webhook"
require_relative "server/webhook_receiver"

module Vatio
  # The part of this gem that talks to Vatio, and only if you ask for it:
  # `require "vatio/identity"` never loads it, so signing a token for the
  # widget still makes no network call at all.
  #
  # Your backend calls the server API with a server key (`vsk_`) to have the
  # agent write to someone first -- an order that shipped, an appointment
  # tomorrow -- and hears back through a signed webhook.
  #
  #   require "vatio/server"
  #
  #   Vatio::Server.configure do |c|
  #     c.server_key = ENV["VATIO_SERVER_KEY"]
  #     c.workspace  = "acme"          # defaults to Vatio::Identity's audience
  #   end
  #
  #   Vatio::Server.send_message(
  #     to: "+56912345678",
  #     brief: "Order #1042 shipped today with Starken, tracking 99812.",
  #     external_ref: "order-1042-shipped"
  #   )
  module Server
    # Long enough for the person to answer tomorrow and still be signed in
    # when they do -- the token is what lets a private tool run on their
    # reply -- and short enough that a conversation nobody came back to does
    # not stay signed in for good.
    IDENTITY_TTL = 48 * 3600

    class << self
      attr_writer :transport

      def config
        @config ||= Config.new
      end

      def configure
        yield config
        config
      end

      # Net::HTTP unless swapped, which is what Vatio::Server::Testing does.
      def transport
        @transport ||= Transport.new
      end

      # A client for the configured key. Build your own with
      # `Client.new(server_key:, workspace:)` to use two keys at once -- a
      # preview key in staging next to the live one, say.
      def client
        Client.new(config)
      end

      def send_message(**options) = client.send_message(**options)
      def message_status(id) = client.message_status(id)
      def messages(**filters) = client.messages(**filters)
      def templates = client.templates
      def identity_for(**options) = client.identity_for(**options)
    end
  end
end

# Only where there is a queue to put it on. Autoloaded rather than required:
# in a Rails app ActiveJob::Base itself loads lazily, and the job is often
# first named from a controller, before any job class has been. Without
# ActiveJob loaded yet, `on_load` defines it when it is.
if defined?(ActiveJob)
  Vatio::Server.autoload(:SendMessageJob, File.expand_path("server/send_message_job", __dir__))
elsif defined?(ActiveSupport) && ActiveSupport.respond_to?(:on_load)
  ActiveSupport.on_load(:active_job) { require_relative "server/send_message_job" }
end
