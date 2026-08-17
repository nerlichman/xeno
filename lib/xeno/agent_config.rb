# frozen_string_literal: true

module Xeno
  # The config DSL evaluated from agent/agent.rb. Optional — defaults apply when the file is absent.
  #
  #   Xeno.agent do
  #     model "anthropic/claude-sonnet-5"
  #   end
  #
  # Any RubyLLM chat options ride along:
  #
  #   Xeno.agent do
  #     model "my-model", provider: :ollama, assume_model_exists: true
  #   end
  #
  class AgentConfig
    def initialize
      @model_id = nil
      @model_options = {}
      @limits = {}
    end

    # Per-agent token budgets, overriding the global config:
    #
    #   Xeno.agent do
    #     limits input_tokens: 2_000_000, output_tokens: 200_000
    #   end
    #
    # `false` disables an axis even when a global cap is set; an axis left out inherits the global
    # `Xeno.config.max_*_tokens_per_session`.
    def limits(**caps)
      unless caps.empty?
        unknown = caps.keys - %i[input_tokens output_tokens]
        raise ArgumentError, "unknown limit axes: #{unknown.join(', ')}" if unknown.any?

        @limits = @limits.merge(caps)
      end
      @limits
    end

    # The effective cap for one axis: agent override first (false = off), then the global config.
    # nil = unlimited.
    def token_limit(axis, global)
      return nil if @limits[axis] == false

      @limits.fetch(axis, nil) || global
    end

    # DSL setter and reader in one: `model "id", **options` inside the block, `config.model`
    # afterwards.
    def model(id = nil, **options)
      if id
        @model_id = id
        @model_options = options
      end
      @model_id
    end

    def model_options
      @model_options
    end

    def resolved_model
      @model_id || RubyLLM.config.default_model
    end
  end
end
