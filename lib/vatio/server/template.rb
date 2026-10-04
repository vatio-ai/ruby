# frozen_string_literal: true

module Vatio
  module Server
    # A WhatsApp template the key's number can send, from Vatio's mirror of
    # Meta's: its body, how many `{{n}}` parameters that body takes, and the
    # object `send_message` expects as `template:`.
    #
    #   shipped = Vatio::Server.templates.find { |t| t.name == "order_shipped" }
    #   Vatio::Server.send_message(to: phone, brief: brief, template: shipped.with_params("Ana", "#1042"))
    #
    # Empty on a preview key: the preview number's templates are Vatio's.
    Template = Struct.new(
      :name, :language, :category, :status, :rejected_reason, :body, :parameter_count, :example,
      keyword_init: true
    ) do
      def self.from(hash) = Value.build(self, hash)

      def approved? = status == "APPROVED"

      # Strings, in body order. The count is checked here when it is known,
      # because Meta only reports a wrong one by refusing the send.
      def with_params(*params)
        params = params.flatten.map(&:to_s)
        if parameter_count && params.size != parameter_count
          raise ArgumentError, "vatio server: template #{name} (#{language}) takes #{parameter_count} " \
            "param#{"s" unless parameter_count == 1}, got #{params.size}"
        end

        { name: name, language: language, params: params }
      end
    end
  end
end
