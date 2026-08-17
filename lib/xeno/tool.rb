# frozen_string_literal: true

module Xeno
  # = Tools
  #
  # A tool is something the agent can do besides talk: look up an order, charge a card, file a
  # ticket. Each tool is a class under agent/tools/, and the model decides when to call it based
  # on the description and parameters you declare:
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
  # The file name is the tool's name on the wire — get_weather.rb is callable as get_weather — and
  # whatever execute returns becomes the tool result the model reads next.
  #
  # Beyond a plain RubyLLM::Tool, a xeno tool runs inside a durable session: it can keep working
  # state in #state, see the #session it runs in, and declare an ::approval policy so a human
  # signs off before anything irreversible happens.
  class Tool < RubyLLM::Tool
    class << self
      # The runtime name the model calls this tool by, taken from the path:
      # agent/tools/get_weather.rb defines Xeno::Tools::GetWeather, and the demodulized class name
      # matches the file basename. No suffix stripping: a charge_card_tool.rb must stay callable as
      # charge_card_tool or the slug-keyed approval lookup misses.
      def tool_name
        name.demodulize.underscore
      end

      # The human-in-the-loop gate. Gate anything irreversible or externally visible.
      #
      #   approval :never    # default: runs without asking
      #   approval :once     # asks the first time in a session, then remembered
      #   approval :always   # asks on every call
      #   approval ->(ctx) { ctx.principal&.dig("role") != "admin" }
      #
      # The lambda receives an ApprovalContext (session, turn, tool_name, arguments, principal);
      # truthy means approval is required.
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

    # The session this call is running in — set by the runner before `call`. nil when the tool is
    # exercised outside a session (unit tests calling `Tool.new.call` directly).
    attr_accessor :session

    # The session-scoped KV store: JSON-typed values that survive restarts, never cross sessions,
    # and are cleared by reset. Working state, not long-term memory.
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
