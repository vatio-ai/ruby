# frozen_string_literal: true

require "rails/railtie"

module Vatio
  module Identity
    class Railtie < ::Rails::Railtie
      initializer "vatio.identity.authentication" do
        ActiveSupport.on_load(:action_controller) do
          require_relative "authentication"
        end
      end
    end
  end
end
