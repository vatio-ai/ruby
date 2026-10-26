# frozen_string_literal: true

require "active_job"

module Vatio
  module Server
    # Lets a Vatio::Server::Job be an ActiveJob argument:
    # `perform_later(vatio_job, ...)` stores its Hash and `perform` gets the
    # Job back.
    class JobSerializer < ActiveJob::Serializers::ObjectSerializer
      def serialize(job) = super(job.to_h)

      def deserialize(hash) = Job.from(hash)

      def klass = Job
    end
  end
end

ActiveJob::Serializers.add_serializers(Vatio::Server::JobSerializer)
