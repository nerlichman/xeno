# frozen_string_literal: true

require "test_helper"

# per-session token budgets — checked independently per axis BEFORE
# each model call from persisted usage; the crossing call finishes and the
# NEXT one trips deterministically (budget.exceeded + turn.failed). Reset
# recovers.
class BudgetTest < ActiveSupport::TestCase
  include ActiveJob::TestHelper

  class Echo < Xeno::Tool
    description "Echoes."

    def execute
      { ok: true }
    end
  end

  setup do
    @old_input = Xeno.config.max_input_tokens_per_session
    @old_output = Xeno.config.max_output_tokens_per_session
  end

  teardown do
    Xeno.config.max_input_tokens_per_session = @old_input
    Xeno.config.max_output_tokens_per_session = @old_output
  end

  # Every model call reports input 50 / output 10.
  def start_metered_fake
    start_fake_llm do |body|
      FakeLLM.text("answer to: #{FakeLLM.last_user_content(body)}", usage: { prompt: 50, completion: 10 })
    end
  end

  def run_turn(session, definition)
    Xeno::TurnRunner.new(session.turns.order(:sequence).last, definition: definition).run
  end

  test "a tiny input cap trips exactly at the boundary, before any model call" do
    fake = start_metered_fake
    definition = TestDefinition.new
    Xeno.config.max_input_tokens_per_session = 100 # exactly two 50-token calls

    session = Xeno::Session.open!(message: "one", definition: definition)
    assert_equal :completed, run_turn(session, definition) # used: 50 < 100
    session.stage_turn!("two", definition: definition)
    assert_equal :completed, run_turn(session, definition) # 50 < 100 pre-call; used: 100 after
    assert_equal 2, fake.requests.size

    session.stage_turn!("three", definition: definition)
    assert_equal :failed, run_turn(session, definition) # 100 >= 100: trips BEFORE the call

    assert_equal 2, fake.requests.size, "no model call happens past the boundary"
    turn = session.turns.order(:sequence).last
    assert_equal "failed", turn.reload.status
    assert_match(/input token budget exceeded \(100\/100\)/, turn.error["message"])

    event = session.events.where(event_type: "budget.exceeded").sole
    assert_equal({ "turn_id" => turn.id, "axis" => "input", "used" => 100, "limit" => 100 }, event.data)
    assert_equal "turn.failed", session.events.order(:index).last.event_type
    assert session.reload.active?, "the session survives; reset is the recovery"
  end

  test "one token of headroom lets the call through (the crossing call finishes)" do
    fake = start_metered_fake
    definition = TestDefinition.new
    Xeno.config.max_input_tokens_per_session = 101

    session = Xeno::Session.open!(message: "one", definition: definition)
    run_turn(session, definition)
    session.stage_turn!("two", definition: definition)
    run_turn(session, definition) # pre-call: 50 < 101 → runs, finishing at 100
    session.stage_turn!("three", definition: definition)
    assert_equal :completed, run_turn(session, definition) # 100 < 101 → allowed to cross

    assert_equal 3, fake.requests.size
    assert_equal 150, session.chat.ruby_llm_usages.sum(:input_tokens)
  end

  test "the output axis is checked independently" do
    start_metered_fake
    definition = TestDefinition.new
    Xeno.config.max_output_tokens_per_session = 10 # one 10-token completion spends it

    session = Xeno::Session.open!(message: "one", definition: definition)
    assert_equal :completed, run_turn(session, definition)
    session.stage_turn!("two", definition: definition)
    assert_equal :failed, run_turn(session, definition)

    event = session.events.where(event_type: "budget.exceeded").sole
    assert_equal "output", event.data["axis"]
  end

  test "a mid-turn trip fails cleanly: executed tools stay answered, the transcript stays provider-legal" do
    fake = start_fake_llm do |body|
      if FakeLLM.tool_result_in_current_turn?(body)
        FakeLLM.text("done", usage: { prompt: 80, completion: 10 })
      else
        FakeLLM.tool_call("echo", {}, id: "call_budget_#{SecureRandom.hex(4)}", usage: { prompt: 60, completion: 10 })
      end
    end
    definition = TestDefinition.new(tools: { "echo" => Echo })
    Xeno.config.max_input_tokens_per_session = 60

    session = Xeno::Session.open!(message: "use the tool", definition: definition)
    assert_equal :failed, run_turn(session, definition)

    # The tool executed (checkpointed) before the budget check tripped the
    # SECOND call; its result is in the transcript, nothing dangles.
    assert_equal 1, session.turns.sole.actions.where(status: "completed").count
    assert fake.requests.all? { |r| FakeLLM.well_formed_tool_calls?(r) }
    assert_equal "budget.exceeded",
      session.events.order(:index).to_a[-2].event_type
  end

  test "per-agent limits override the global, and false disables an axis" do
    fake = start_metered_fake
    Xeno.config.max_input_tokens_per_session = 1_000_000

    tight = TestDefinition.new
    tight.config.limits(input_tokens: 50)
    session = Xeno::Session.open!(message: "one", definition: tight)
    assert_equal :completed, run_turn(session, tight)
    session.stage_turn!("two", definition: tight)
    assert_equal :failed, run_turn(session, tight), "the tighter agent cap wins"

    Xeno.config.max_input_tokens_per_session = 50
    unlimited = TestDefinition.new
    unlimited.config.limits(input_tokens: false)
    s2 = Xeno::Session.open!(message: "one", definition: unlimited)
    assert_equal :completed, run_turn(s2, unlimited)
    s2.stage_turn!("two", definition: unlimited)
    assert_equal :completed, run_turn(s2, unlimited), "false disables the axis despite the global cap"
    assert_equal 3, fake.requests.size, "tight: 1 call then a pre-call trip; unlimited: 2 calls"
  end

  test "reset recovers: a fresh session on the same handle runs fine" do
    start_metered_fake
    definition = TestDefinition.new
    Xeno.config.max_input_tokens_per_session = 50

    session = Xeno::Session.open!(message: "one", definition: definition, continuation_token: "http:budget-reset")
    run_turn(session, definition)
    session.stage_turn!("two", definition: definition)
    assert_equal :failed, run_turn(session, definition)

    session.finish!("completed") # what reset does; releases the token
    fresh = Xeno::Session.open!(message: "hello again", definition: definition, continuation_token: "http:budget-reset")
    assert_equal :completed, run_turn(fresh, definition), "fresh session, fresh usage"
  end

  test "unknown limit axes are rejected at the DSL" do
    assert_raises(ArgumentError) { Xeno::AgentConfig.new.limits(tokens: 5) }
  end
end
