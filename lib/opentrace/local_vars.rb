# frozen_string_literal: true

module OpenTrace
  module LocalVars
    MAX_VARS = 10
    MAX_VALUE_LENGTH = 500

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

        value = binding_obj.local_variable_get(name)
        {
          name: name.to_s,
          value: safe_inspect(value),
          type: value.class.name
        }
      end
    rescue StandardError
      nil
    end

    def safe_inspect(value)
      str = value.inspect
      str.length > MAX_VALUE_LENGTH ? str[0, MAX_VALUE_LENGTH] + "..." : str
    rescue StandardError
      "#<uninspectable>"
    end
  end
end
