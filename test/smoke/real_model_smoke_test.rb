# frozen_string_literal: true

require "test_helper"

# Real-model smoke: a live model on NVIDIA's OpenAI-compatible endpoint
# drives one full park → rehydrate → approve → resume cycle through the
# runtime. Rate-limited and nondeterministic, so this NEVER gates a
# milestone: it skips cleanly without NVIDIA_API_KEY (the default suite
# never sources .env — run it via script/smoke.sh) and skips (not fails)
# when a model declines to call tools.
class RealModelSmokeTest < ActiveSupport::TestCase
  KEY = ENV["NVIDIA_API_KEY"]
  BASE = "https://integrate.api.nvidia.com/v1"
  CANDIDATES = [ "minimax/minimax-m3", "meta/llama-3.3-70b-instruct" ].freeze

  class Probe < Xeno::Tool
    description "Echo probe. Call this when asked."
    parameter :value, type: :integer, description: "Any integer"

    def execute(value:)
      { echoed: value }
    end
  end

  class SmokeCharge < Xeno::Tool
    description "Charge the card. Requires human approval; call it when asked to charge."
    parameter :amount_cents, type: :integer, description: "Amount in cents"
    approval :always

    class << self
      attr_accessor :executions
    end

    def execute(amount_cents:)
      self.class.executions += 1
      { status: "succeeded", charge_id: "ch_smoke_#{amount_cents}" }
    end
  end

  setup do
    skip "NVIDIA_API_KEY not set — smoke suite runs via script/smoke.sh" unless KEY

    SmokeCharge.executions = 0
    RubyLLM.configure do |c|
      c.openai_api_base = BASE
      c.openai_api_key = KEY
    end
  end

  teardown do
    if KEY
      RubyLLM.configure do |c|
        c.openai_api_base = nil
        c.openai_api_key = nil
      end
    end
  end

  # One request with a trivial tool: does this model emit tool calls
  # through our exact path (OpenAI provider, chat-completions protocol)?
  def probe(model)
    chat = RubyLLM.chat(model: model, provider: :openai, protocol: :chat_completions,
                        assume_model_exists: true).with_tools(Probe)
    chat.ask_later("Call the probe tool with value 7. You must use the tool.")
    chat.generate.tool_call?
  rescue StandardError => e
    warn "smoke probe #{model}: #{e.class}: #{e.message}"
    false
  end

  test "a real model drives park -> rehydrate -> approve -> resume" do
    model = CANDIDATES.find { |candidate| probe(candidate) }
    skip "no candidate model emitted tool calls through our path" unless model

    puts "\n[smoke] using #{model}"
    definition = TestDefinition.new(
      model: model,
      model_options: { provider: :openai, protocol: :chat_completions, assume_model_exists: true },
      tools: { "smoke_charge" => SmokeCharge },
      instructions: "You are a billing assistant. When asked to charge, you MUST call the " \
                    "smoke_charge tool. After the tool result, confirm briefly."
    )

    session = Xeno::Session.open!(
      message: "Please charge 42 cents now using the smoke_charge tool.",
      definition: definition
    )
    turn = session.turns.order(:sequence).last

    result = Xeno::TurnRunner.new(turn, definition: definition).run
    skip "model answered without calling smoke_charge (nondeterministic) — result: #{result}" unless result == :parked

    assert_equal 0, SmokeCharge.executions
    action = turn.actions.where(status: "pending_approval").sole

    # Object death: everything below runs on freshly loaded rows.
    Xeno::Inputs.approve!(action, principal: { "user" => "smoke" })
    resumed = Xeno::TurnRunner.new(Xeno::Turn.find(turn.id), definition: definition).run

    assert_equal :completed, resumed
    assert_equal 1, SmokeCharge.executions, "approved tool must run exactly once"
    final = session.chat.messages_association.order(:id).last
    assert_equal "assistant", final.role
    assert final.content.present?, "real model must produce a final answer after the injected result"
    puts "[smoke] final answer: #{final.content.to_s.slice(0, 120)}"
  end
end
