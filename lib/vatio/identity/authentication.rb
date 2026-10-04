# frozen_string_literal: true

module Vatio
  module Identity
    # For the other end: your own API, behind a private tool.
    #
    #   class Api::BookingsController < ApplicationController
    #     include Vatio::Identity::Authentication
    #     before_action :authenticate_vatio!
    #
    #     def index
    #       render json: Booking.where(user_id: vatio_subject)
    #     end
    #   end
    #
    # Scope by `vatio_subject` and nothing else. Vatio already refuses to
    # deploy a private tool that takes `user_id` as a parameter -- the model
    # fills parameters and can be talked into filling that one with somebody
    # else's id -- and the same reasoning applies one layer down: an endpoint
    # that accepts an id has to remember to scope it every time, forever, and
    # one that reads the token cannot forget.
    #
    # An app serving several workspaces says which one the request is for,
    # and nil for one that has not connected Vatio, which is a 401:
    #
    #   def vatio_identity_config
    #     current_tenant.vatio_identity_config
    #   end
    module Authentication
      def self.included(base)
        base.helper_method(:vatio_subject, :vatio_principal) if base.respond_to?(:helper_method)
      end

      def vatio_principal
        return @vatio_principal if defined?(@vatio_principal)

        config = vatio_identity_config
        @vatio_principal = config && Identity.verify(vatio_bearer_token, config: config)
      end

      def vatio_subject
        vatio_principal&.subject
      end

      def vatio_signed_in?
        !vatio_principal.nil?
      end

      def authenticate_vatio!
        return if vatio_signed_in?

        render json: { error: "unauthorized" }, status: :unauthorized
      end

      private

      def vatio_identity_config
        Identity.config
      end

      def vatio_bearer_token
        header = request.headers["Authorization"].to_s
        header[/\ABearer (.+)\z/i, 1]
      end
    end
  end
end
