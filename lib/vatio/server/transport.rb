# frozen_string_literal: true

require "net/http"
require "openssl"
require "uri"

module Vatio
  module Server
    # What a transport answers: the status, the headers with downcased names,
    # and the body as it came.
    Response = Struct.new(:status, :headers, :body, keyword_init: true)

    # The one place the gem opens a socket, kept to an interface small enough
    # that Vatio::Server::Testing swaps it for an in-memory one:
    #
    #   call(method:, url:, headers:, body:) -> Response
    #
    # A connection per request. Messages are sent one at a time, a few a
    # minute at most, and a fresh connection is one fewer thing to share
    # between threads.
    class Transport
      # Everything that means "Vatio did not answer", as opposed to "Vatio
      # said no". All of it is worth retrying.
      NETWORK_ERRORS = [
        Timeout::Error, IOError, EOFError, SocketError, SystemCallError, OpenSSL::SSL::SSLError
      ].freeze

      def call(method:, url:, headers: {}, body: nil, open_timeout: nil, read_timeout: nil)
        uri = URI.parse(url)
        request = Net::HTTP.const_get(method.to_s.capitalize).new(uri.request_uri)
        headers.each { |name, value| request[name] = value }
        request.body = body if body

        http = Net::HTTP.new(uri.host, uri.port)
        http.use_ssl = uri.scheme == "https"
        http.open_timeout = open_timeout || Config::DEFAULT_OPEN_TIMEOUT
        http.read_timeout = read_timeout || Config::DEFAULT_READ_TIMEOUT
        # A POST is never resent behind the caller's back: it is the
        # idempotency key, not Net::HTTP, that makes a resend safe.
        http.max_retries = 0 if http.respond_to?(:max_retries=)

        response = http.start { |connection| connection.request(request) }
        Response.new(status: response.code.to_i, headers: response.each_header.to_h, body: response.body.to_s)
      rescue *NETWORK_ERRORS => e
        raise Unavailable.new("vatio server: #{uri&.host} did not answer (#{e.class}: #{e.message})",
          code: e.is_a?(Timeout::Error) ? "timeout" : "network_error")
      end
    end
  end
end
