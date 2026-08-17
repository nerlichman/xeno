# frozen_string_literal: true

require "ruby_llm"

require "xeno/version"
require "xeno/errors"
require "xeno/configuration"
require "xeno/agent_config"
require "xeno/agent_definition"
require "xeno/tool"
require "xeno/ask_question"
require "xeno/approval_context"
require "xeno/inputs"
require "xeno/arguments"
require "xeno/session_state"
require "xeno/channels"
require "xeno/channels/slack"
require "xeno/hooks"
require "xeno/compaction"
require "xeno/turn_runner"
require "xeno/reaper"
require "xeno/engine"

module Xeno
  class << self
    # The app's agent directory. Defaults to <Rails.root>/agent; overridable (standalone mode,
    # tests).
    attr_writer :agent_root

    def agent_root
      @agent_root ||= Rails.root.join("agent")
    end

    # The agent/agent.rb entry point:
    #
    #   Xeno.agent do
    #     model "anthropic/claude-sonnet-5"
    #   end
    #
    def agent(&block)
      config = AgentConfig.new
      config.instance_eval(&block) if block
      @captured_agent_config = config
    end

    def capture_agent_config # :nodoc: loader bookkeeping around `load agent.rb`
      @captured_agent_config = nil
      yield
    end

    def captured_agent_config # :nodoc:
      @captured_agent_config
    end

    # The agent/instructions.rb entry point — dynamic instructions resolved at turn-stage time with
    # the session context:
    #
    #   Xeno.instructions do |context|
    #     "You are helping #{context.principal&.dig("name") || "a guest"}."
    #   end
    #
    # Composes with the static instructions.md: static first, the block's return appended. The block
    # runs on EVERY turn stage — keep it fast.
    def instructions(&block)
      @captured_instructions = block
    end

    def capture_instructions # :nodoc: loader bookkeeping around `load instructions.rb`
      @captured_instructions = nil
      yield
    end

    def captured_instructions # :nodoc:
      @captured_instructions
    end

    # The agent/hooks/*.rb entry point — observe-only handlers for stream events (any type from the
    # vocabulary, or "*"):
    #
    #   Xeno.hook "turn.completed" do |event|
    #     Metrics.increment("agent.turns")
    #   end
    #
    # Handlers fire after the event commits, at-least-once (replays re-emit). Raising never breaks
    # the runtime.
    def hook(event_type, &block)
      raise ArgumentError, "Xeno.hook requires a block" unless block

      (@captured_hooks ||= {})[event_type.to_s] ||= []
      @captured_hooks[event_type.to_s] << block
    end

    def capture_hooks # :nodoc: loader bookkeeping around `load hooks/*.rb`
      @captured_hooks = {}
      yield
      @captured_hooks
    end

    # The resolved agent definition, discovered on first use and cached. Rails reloading resets it
    # (see engine's to_prepare).
    def definition
      @definition ||= AgentDefinition.load(agent_root, name: default_agent_name)
    end

    def reset_definition!
      @definition = nil
    end

    def default_agent_name
      Rails.application.class.module_parent_name.underscore
    end

    # Dev routes exist in development, or when XENO_DEV_ROUTES is exactly "1"/"true" (a truthy-check
    # would let "0" enable them).
    def dev_routes_enabled?
      Rails.env.development? || %w[1 true].include?(ENV["XENO_DEV_ROUTES"].to_s)
    end
  end
end
