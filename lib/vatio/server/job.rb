# frozen_string_literal: true

require "json"
require "time"
require "uri"

module Vatio
  module Server
    # A job an async tool started: a tool declared `async:` in its tools/*.yml
    # is called with a job id and the URL to post the result to, and its
    # endpoint answers 202 and does the work later. This is that job, on your
    # side: read it in the endpoint, put it on your queue, and report back.
    #
    #   class Vatio::MatchesController < ApplicationController
    #     include Vatio::Server::AsyncTool
    #
    #     def create
    #       MatchTherapistsJob.perform_later(vatio_job, reason: params[:reason], area: params[:area])
    #       accept_vatio_job(message: "Finding matches; this usually takes about two minutes.")
    #     end
    #   end
    #
    #   class MatchTherapistsJob < ApplicationJob
    #     def perform(vatio_job, reason:, area:)
    #       vatio_job.run do |job|
    #         job.progress("Reviewing 12 therapists in your area", notify: true)
    #         { result: "ok", message: "2 found", data: { therapists: find_matches(reason, area) } }
    #       end
    #     end
    #   end
    #
    # What a job posts is what your endpoint would have answered had it been
    # fast: Vatio reads it through the tool's `respond:`, writes it into the
    # conversation as the tool's answer and has the agent give it to the
    # person. No server key is needed: the callback URL is signed and names
    # this one job. Treat it as a secret -- `inspect` leaves it out, but
    # your queue stores it.
    class Job
      HEADER_ID = "X-Vatio-Job-Id"
      HEADER_CALLBACK_URL = "X-Vatio-Callback-Url"
      HEADER_EXPIRES_AT = "X-Vatio-Job-Expires-At"

      CALLBACK_PATH = "/api/jobs/v1/"

      # Seconds between the attempts to post one callback when Vatio is
      # unreachable or rate limiting. Retried here rather than by your queue,
      # which would redo the work to post it again.
      RETRY_WAITS = [ 1, 4, 15 ].freeze

      # The answer to a callback: the job's status after it ("pending" after
      # progress, "completed" or "failed" after the result), and whether this
      # result had already been taken.
      State = Struct.new(:job_id, :status, :duplicate, keyword_init: true) do
        def duplicate? = duplicate == true
      end

      class << self
        # How it waits between attempts. Vatio::Server::Testing waits for
        # nothing.
        attr_writer :sleeper

        def sleeper = @sleeper || ->(seconds) { sleep(seconds) }

        # The job a request carries, or nil when it carries none: the tool is
        # not declared `async:`, or the call is not from Vatio. Takes
        # Rails' `request.headers`, a Rack env or a Hash of header names.
        #
        # A callback URL on any host but Vatio's (`base_url`) is refused: a
        # request that could choose where your worker posts a customer's
        # data must not get to.
        def from_headers(headers, config: Server.config)
          id = header(headers, HEADER_ID)
          url = header(headers, HEADER_CALLBACK_URL)
          return nil if blank?(id) || blank?(url)

          new(id: id, callback_url: url, expires_at: header(headers, HEADER_EXPIRES_AT), config: config)
        end

        # The inverse of `to_h`: for a queue that stores Hashes (Sidekiq, a
        # database row). ActiveJob takes the Job itself.
        def from(hash, config: Server.config)
          hash = hash.to_h.transform_keys(&:to_s)
          new(id: hash["id"], callback_url: hash["callback_url"], expires_at: hash["expires_at"], config: config)
        end

        private

        def header(headers, name)
          value = [ name, name.downcase, "HTTP_#{name.upcase.tr("-", "_")}" ].lazy.map { |key| headers[key] }
            .find { |candidate| !blank?(candidate) }
          value&.to_s&.strip
        end

        def blank?(value) = value.nil? || value.to_s.strip.empty?
      end

      attr_reader :id, :callback_url, :expires_at

      def initialize(id:, callback_url:, expires_at: nil, config: Server.config)
        @id = id.to_s
        @callback_url = callback_url.to_s
        @expires_at = parse_time(expires_at)
        @config = config
        check_callback_url!
      end

      # How far along it is. Kept for when the person asks how it is going;
      # with `notify: true` the agent tells them now. For jobs that take
      # minutes, not for every step.
      def progress(text, notify: false)
        post({ progress: text.to_s, notify: notify })
      end

      # The result: `respond:` maps `data` (or whatever else you send) as it
      # maps your endpoint's answer, and `message` is relayed when the tool
      # declares none.
      def complete(message: nil, data: nil, **fields)
        respond({ result: "ok", message: message, data: data }.compact.merge(fields))
      end

      # It could not be done. The agent tells the person, from `message`.
      def failed(message, error_key: nil, **fields)
        respond({ result: "error", message: message.to_s, error_key: error_key }.compact.merge(fields))
      end

      # The result as your endpoint would have answered it, exactly.
      def respond(body)
        raise ArgumentError, "vatio job: the result must be a Hash, got #{body.class}" unless body.is_a?(Hash)

        post(body)
      end

      FAILURE_MESSAGE = "It could not be finished this time."

      # Runs the block and posts what it returns (a Hash, as `respond`) as
      # the result. If it raises, the job is reported failed with
      # `failure_message` -- the person hears it now rather than when the
      # job times out -- and the error is raised on, for your queue and your
      # error tracker. If Vatio says the job is over (timed out, or the
      # person called it off) while it runs, it stops there and returns nil.
      def run(failure_message: FAILURE_MESSAGE)
        result = yield(self)
        respond(result)
      rescue JobClosed
        nil
      rescue StandardError => e
        begin
          failed(failure_message)
        rescue Error
          nil
        end
        raise e
      end

      def expired?
        !expires_at.nil? && Time.now >= expires_at
      end

      def to_h
        { "id" => id, "callback_url" => callback_url, "expires_at" => expires_at&.utc&.iso8601 }
      end

      def ==(other)
        other.is_a?(Job) && other.id == id && other.callback_url == callback_url
      end
      alias eql? ==

      def hash = [ id, callback_url ].hash

      # Without the callback URL: it is the job's credential.
      def inspect
        "#<#{self.class.name} #{id}#{" expires_at=#{expires_at.utc.iso8601}" if expires_at}>"
      end
      alias to_s inspect

      private

      def post(body)
        attempt = 0
        begin
          attempt += 1
          deliver(body)
        rescue RateLimited, Unavailable
          raise if attempt > RETRY_WAITS.size

          self.class.sleeper.call(RETRY_WAITS[attempt - 1])
          retry
        end
      end

      def deliver(body)
        response = Server.transport.call(
          method: :post, url: callback_url, body: JSON.generate(body),
          headers: { "Accept" => "application/json", "Content-Type" => "application/json",
                     "User-Agent" => "vatio-sdk-ruby/#{Identity::VERSION}" },
          open_timeout: @config.open_timeout, read_timeout: @config.read_timeout
        )
        parsed = parse(response.body)
        raise Error.from_response(response.status, parsed, response.headers) unless (200..299).cover?(response.status)

        parsed = {} unless parsed.is_a?(Hash)
        State.new(job_id: parsed["job_id"] || id, status: parsed["status"], duplicate: parsed["duplicate"] == true)
      end

      def parse(body)
        return nil if body.nil? || body.empty?

        JSON.parse(body)
      rescue JSON::ParserError
        nil
      end

      def parse_time(value)
        return value if value.is_a?(Time)
        return nil if value.nil? || value.to_s.strip.empty?

        Time.iso8601(value.to_s)
      rescue ArgumentError
        nil
      end

      def check_callback_url!
        uri = URI.parse(callback_url)
        base = URI.parse(@config.base_url!)
        same_host = uri.host&.downcase == base.host&.downcase && uri.scheme == base.scheme && uri.port == base.port
        return if same_host && uri.path.start_with?(CALLBACK_PATH)

        raise InvalidRequest.new("vatio job: the callback URL is not Vatio's (#{base.scheme}://#{base.host})",
          code: "invalid_callback_url")
      rescue URI::InvalidURIError
        raise InvalidRequest.new("vatio job: the callback URL is not a URL", code: "invalid_callback_url")
      end
    end
  end
end
