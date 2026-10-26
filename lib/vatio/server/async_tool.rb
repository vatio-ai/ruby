# frozen_string_literal: true

module Vatio
  module Server
    # For the controller behind a tool declared `async:`: the job Vatio sent
    # with the call, and the 202 that says it was accepted.
    #
    #   class Vatio::MatchesController < ApplicationController
    #     include Vatio::Server::AsyncTool
    #
    #     def create
    #       return render(json: match_now) unless vatio_job   # not async: answer as any tool
    #
    #       MatchTherapistsJob.perform_later(vatio_job, reason: params[:reason], area: params[:area])
    #       accept_vatio_job(message: "Finding matches; this usually takes about two minutes.")
    #     end
    #   end
    #
    # Check the tool's own credential as you would for any tool: the job
    # headers say where to post, not who is calling.
    module AsyncTool
      private

      # The Vatio::Server::Job this request carries, or nil when it carries
      # none.
      def vatio_job
        return @vatio_job if defined?(@vatio_job)

        @vatio_job = Job.from_headers(request.headers)
      end

      # 202: the agent is told the job started and the person that it is on
      # its way. `message` reaches the agent, so say how long it usually
      # takes.
      def accept_vatio_job(message: nil)
        render json: { message: message }.compact, status: :accepted
      end
    end
  end
end
