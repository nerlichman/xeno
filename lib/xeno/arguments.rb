module Xeno
  # Models send JSON-typed arguments loosely — the first field run had
  # llama sending "4200" (String) for an integer-typed parameter, which
  # flowed into execute unchecked. Casts each argument per the tool's
  # declared parameter type; anything uncoercible becomes a validation
  # error the runner turns into an error tool result (the model retries
  # with fixed arguments) — never an exception into execute.
  module Arguments
    module_function

    # Returns [coerced_arguments, errors]. Undeclared keys pass through
    # untouched (schema-based tools declare nothing here).
    def coerce(tool_class, arguments)
      declared = tool_class.respond_to?(:declared_parameters) ? tool_class.declared_parameters : {}
      return [ arguments, [] ] if declared.empty? || !arguments.is_a?(Hash)

      coerced = {}
      errors = []
      arguments.each do |key, value|
        parameter = declared[key.to_sym]
        if parameter.nil? || value.nil?
          coerced[key] = value
          next
        end

        begin
          coerced[key] = cast(value, parameter.type.to_s)
        rescue ArgumentError, TypeError
          errors << "#{key}: expected #{parameter.type}, got #{value.inspect}"
        end
      end
      [ coerced, errors ]
    end

    def cast(value, type)
      case type
      when "integer" then value.is_a?(Integer) ? value : Integer(value, exception: true)
      when "number"  then value.is_a?(Numeric) ? value : Float(value)
      when "boolean" then boolean(value)
      when "string"  then value.is_a?(String) ? value : scalar_to_string(value)
      when "array"   then value.is_a?(Array) ? value : raise(TypeError)
      when "object"  then value.is_a?(Hash) ? value : raise(TypeError)
      else value
      end
    end

    def boolean(value)
      case value
      when true, false then value
      when "true", "1", 1 then true
      when "false", "0", 0 then false
      else raise TypeError
      end
    end

    def scalar_to_string(value)
      raise TypeError if value.is_a?(Array) || value.is_a?(Hash)

      value.to_s
    end
  end
end
