# frozen_string_literal: true

module Vatio
  module Server
    ConfigurationError = Class.new(StandardError)

    # The server key and the workspace it belongs to, and where to reach it.
    #
    # The key already names its workspace and environment; the slug goes in
    # the path anyway, and Vatio refuses a request whose two disagree. That is
    # what keeps a key pasted into the wrong service from quietly writing to
    # another workspace's customers.
    class Config
      DEFAULT_BASE_URL = "https://vatio.ai"

      # A send is recorded and queued, never performed in the request, so it
      # answers in milliseconds; anything slower than this is not coming.
      DEFAULT_OPEN_TIMEOUT = 5
      DEFAULT_READ_TIMEOUT = 15

      # `webhook_secret` is the endpoint's `whsec_`, read by WebhookReceiver
      # unless the controller defines `vatio_webhook_secret` itself.
      attr_accessor :server_key, :base_url, :open_timeout, :read_timeout, :webhook_secret
      attr_writer :workspace

      def initialize(server_key: nil, workspace: nil, base_url: DEFAULT_BASE_URL,
                     open_timeout: DEFAULT_OPEN_TIMEOUT, read_timeout: DEFAULT_READ_TIMEOUT, webhook_secret: nil)
        @server_key = server_key
        @workspace = workspace
        @base_url = base_url
        @open_timeout = open_timeout
        @read_timeout = read_timeout
        @webhook_secret = webhook_secret
      end

      # The slug, falling back to Vatio::Identity's audience: it is the same
      # workspace, and saying it twice is a chance to say it differently.
      def workspace
        value = @workspace.to_s.strip
        value = Identity.config.audience.to_s.strip if value.empty?
        value.empty? ? nil : value
      end

      def workspace!
        workspace || raise(ConfigurationError, missing("workspace (your Vatio workspace slug)"))
      end

      # Never logged, never put in an error message.
      def server_key!
        value = server_key.to_s.strip
        return value unless value.empty?

        raise ConfigurationError, missing("server_key (a vsk_ key from `vatio keys create`)")
      end

      def base_url!
        base_url.to_s.strip.delete_suffix("/").then { |url| url.empty? ? DEFAULT_BASE_URL : url }
      end

      private

      def missing(name)
        "vatio server: #{name} is not configured -- see Vatio::Server.configure"
      end
    end
  end
end
