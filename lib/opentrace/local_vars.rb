# frozen_string_literal: true

module OpenTrace
  module LocalVars
    MAX_VARS = 10
    MAX_VALUE_LENGTH = 500

    SENSITIVE_PATTERNS = %w[
      password passwd secret token api_key apikey
      authorization auth_token access_token refresh_token
      credit_card card_number cvv ssn private_key
      session_id cookie credential
    ].freeze

    module_function

    # Capture local variables from an explicit binding.
    # Called by the user in their rescue blocks:
    #
    #   rescue => e
    #     OpenTrace.capture_binding(e, binding)
    #     raise
    #   end
    #
    # Returns: Array of { name:, value:, type: } or nil
    def capture(binding_obj)
      return nil unless binding_obj.is_a?(Binding)

      vars = binding_obj.local_variables.first(MAX_VARS)
      vars.filter_map do |name|
        # Skip internal variables (_, _1, etc.)
        next if name.to_s.start_with?("_")

        name_s = name.to_s.downcase
        if sensitive_name?(name_s)
          { name: name.to_s, value: "[FILTERED]", type: "filtered" }
        else
          value = binding_obj.local_variable_get(name)
          { name: name.to_s, value: safe_inspect(value), type: value.class.name }
        end
      end
    rescue StandardError
      nil
    end

    def sensitive_name?(name)
      SENSITIVE_PATTERNS.any? { |pattern| name.include?(pattern) }
    end

    def safe_inspect(value)
      str = value.inspect
      str.length > MAX_VALUE_LENGTH ? str[0, MAX_VALUE_LENGTH] + "..." : str
    rescue StandardError
      "#<uninspectable>"
    end
  end
end
