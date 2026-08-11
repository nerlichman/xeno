# frozen_string_literal: true

module Xeno
  # Base class for agent tools: a RubyLLM::Tool with path-derived naming, an
  # approval policy, and access to the running session.
  #
  #   # agent/tools/get_weather.rb
  #   class Xeno::Tools::GetWeather < Xeno::Tool
  #     description "Return current weather for a city."
  #     parameter :city, description: "City name"
  #
  #     def execute(city:)
  #       { city: city, condition: "Sunny" }
  #     end
  #   end
  #
  class Tool < RubyLLM::Tool
    class << self
      # The runtime name the model calls this tool by. The path supplies the
      # name: Zeitwerk guarantees agent/tools/get_weather.rb
      # defines Xeno::Tools::GetWeather, so the demodulized class name and
      # the file basename are the same thing. No suffix-stripping: a
      # `charge_card_tool.rb` must be callable as `charge_card_tool`, or the
      # runtime's slug-keyed lookup misses and the approval gate is skipped.
      def tool_name
        name.demodulize.underscore
      end

      # The human-in-the-loop gate. Anything irreversible or externally
      # visible should be gated — approvals are the guardrail in an
      # in-app-tools trust model.
      #
      #   approval :never    # default: runs without asking
      #   approval :once     # asks the first time in a session, then remembered
      #   approval :always   # asks on every call
      #   approval ->(ctx) { ctx.principal&.dig("role") != "admin" }
      #
      # The lambda receives an ApprovalContext (session, turn, tool_name,
      # arguments, principal); truthy means approval is required.
      def approval(policy = nil)
        @approval = policy unless policy.nil?
        return @approval if defined?(@approval) && @approval

        superclass.respond_to?(:approval) ? superclass.approval : :never
      end

      def approval_declared? # :nodoc:
        (defined?(@approval) && !@approval.nil?) ||
          (superclass.respond_to?(:approval_declared?) && superclass.approval_declared?)
      end
    end

    # RubyLLM derives the wire name from the full class name, which would
    # leak the namespace (xeno/tools/get_weather). Use the path-derived name.
    def name
      self.class.tool_name
    end

    # The session this call is running in — set by the runner before
    # `call`. nil when the tool is exercised outside a session (unit tests
    # calling `Tool.new.call` directly).
    attr_accessor :session

    # The session-scoped KV store: JSON-typed values that survive restarts,
    # never cross sessions, and are cleared by reset. Working state, not
    # long-term memory.
    #
    #   def execute(city:)
    #     searches = state.get("searches").to_i + 1
    #     state.update("searches" => searches, "last_city" => city)
    #     ...
    #   end
    def state
      raise Xeno::Error, "session state is only available while running inside a session" unless session

      session.state
    end
  end
end
