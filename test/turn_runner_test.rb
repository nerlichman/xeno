# frozen_string_literal: true

require "test_helper"

class TurnRunnerTest < ActiveSupport::TestCase
  # Tools with observable side effects so replay semantics are provable.
  class Echo < Xeno::Tool
    description "Echoes back."
    parameter :text, description: "Text"

    def execute(text:)
      { echoed: text }
    end
  end

  class CountedCharge < Xeno::Tool
    description "Records an execution; raises if ever run twice."
    parameter :amount, type: :integer, description: "Amount"

    class << self
      attr_accessor :executions
    end

    def execute(amount:)
      self.class.executions += 1
      raise "EXECUTED TWICE (#{self.class.executions})" if self.class.executions > 1

      { charged: amount }
    end
  end

  class CallAware < Xeno::Tool
    description "Echoes the id of the tool call that invoked it."
    parameter :text, description: "Text"

    def execute(text:, tool_call: nil)
      { text: text, call_id: tool_call&.id }
    end
  end

  setup do
    CountedCharge.executions = 0
  end

  def start_session(definition, message: "hi")
    session = Xeno::Session.open!(message: message, definition: definition)
    [ session, session.turns.order(:sequence).last ]
  end

  test "plain text turn completes and emits the event arc" do
    start_fake_llm # default: text "ok"
    definition = TestDefinition.new
    session, turn = start_session(definition)

    result = Xeno::TurnRunner.new(turn, definition: definition).run

    assert_equal :completed, result
    assert_equal "completed", turn.reload.status
    assert_equal 1, turn.steps_count

    types = session.events.order(:index).pluck(:event_type)
    assert_equal %w[session.started message.received turn.started step.started step.completed
                    message.completed turn.completed], types

    transcript = session.chat.messages_association.order(:id).pluck(:role, :content)
    assert_equal [ "system", "user", "assistant" ], transcript.map(&:first)
    assert_equal "ok", transcript.last.last
  end

  test "tool turn: executes, records the action, injects, finishes" do
    fake = start_fake_llm do |body|
      if FakeLLM.tool_result?(body)
        FakeLLM.text("echoed!")
      else
        FakeLLM.tool_call("echo", { text: "yo" }, id: "call_rt_echo")
      end
    end
    definition = TestDefinition.new(tools: { "echo" => Echo })
    session, turn = start_session(definition)

    assert_equal :completed, Xeno::TurnRunner.new(turn, definition: definition).run

    action = turn.actions.sole
    assert_equal "completed", action.status
    assert_equal "echo", action.tool_name
    assert_equal({ "text" => "yo" }, action.input)
    assert_includes action.output["content"], "yo"

    roles = session.chat.messages_association.order(:id).pluck(:role)
    assert_equal %w[system user assistant tool assistant], roles

    types = session.events.order(:index).pluck(:event_type)
    assert_includes types, "actions.requested"
    assert_includes types, "action.result"

    # The fake saw the tool schema and got the result linked correctly.
    resume = fake.requests.last
    assert_equal "call_rt_echo", resume["messages"].last["tool_call_id"]
  end

  test "a tool declaring the tool_call keyword receives its own call" do
    start_fake_llm do |body|
      if FakeLLM.tool_result?(body)
        FakeLLM.text("done")
      else
        FakeLLM.tool_call("call_aware", { text: "yo" }, id: "call_rt_aware")
      end
    end
    definition = TestDefinition.new(tools: { "call_aware" => CallAware })
    session, turn = start_session(definition)

    assert_equal :completed, Xeno::TurnRunner.new(turn, definition: definition).run

    action = turn.actions.sole
    assert_equal "completed", action.status
    assert_includes action.output["content"], "call_rt_aware"
  end

  test "recorded tool calls are never re-executed after a mid-turn failure" do
    generate_failures = 1
    start_fake_llm do |body|
      if FakeLLM.tool_result?(body)
        if generate_failures.positive?
          generate_failures -= 1
          { "choices" => [], "error" => { "message" => "injected transient failure" } }
        else
          FakeLLM.text("done")
        end
      else
        FakeLLM.tool_call("counted_charge", { amount: 42 }, id: "call_rt_charge")
      end
    end
    definition = TestDefinition.new(tools: { "counted_charge" => CountedCharge })
    session, turn = start_session(definition)

    # First run: tool executes + records, then the follow-up generate blows up.
    assert_raises(StandardError) { Xeno::TurnRunner.new(turn, definition: definition).run }
    assert_equal 1, CountedCharge.executions
    assert_equal "pending", turn.reload.status, "claim released for retry"
    assert turn.error["message"].present?

    # Retry (a fresh runner, as ActiveJob would): fast-forwards, never re-runs the tool.
    assert_equal :completed, Xeno::TurnRunner.new(turn.reload, definition: definition).run
    assert_equal 1, CountedCharge.executions, "recorded call must not re-execute"
    assert_equal "completed", turn.reload.status
  end

  test "two concurrent claims: exactly one proceeds" do
    start_fake_llm
    definition = TestDefinition.new
    _session, turn = start_session(definition)

    first = turn.claim!
    second = Xeno::Turn.find(turn.id).claim!

    assert first, "first claim wins"
    assert_nil second, "second claim exits quietly"
  end

  test "stale heartbeat is reclaimable and the zombie gets fenced" do
    start_fake_llm
    definition = TestDefinition.new
    _session, turn = start_session(definition)

    zombie_token = turn.claim!
    turn.reload.update_columns(heartbeat_at: 1.hour.ago) # owner died silently

    new_token = Xeno::Turn.find(turn.id).claim!
    assert new_token, "stale turn must be reclaimable"
    assert_operator new_token, :>, zombie_token

    assert_raises(Xeno::Fenced) { turn.heartbeat!(zombie_token) }
    assert Xeno::Turn.find(turn.id).heartbeat!(new_token)
  end

  test "max steps guard fails the turn instead of looping forever" do
    calls = 0
    start_fake_llm do |_body|
      calls += 1
      FakeLLM.tool_call("echo", { text: "again" }, id: "call_loop_#{calls}")
    end
    definition = TestDefinition.new(tools: { "echo" => Echo })
    session, turn = start_session(definition)

    original = Xeno.config.max_steps
    Xeno.config.max_steps = 3
    begin
      assert_equal :failed, Xeno::TurnRunner.new(turn, definition: definition).run
    ensure
      Xeno.config.max_steps = original
    end

    assert_equal "failed", turn.reload.status
    assert_match(/exceeded 3 steps/, turn.error["message"])
    assert_includes session.events.pluck(:event_type), "turn.failed"
  end

  test "poisoned turn (attempts exhausted) fails on claim" do
    start_fake_llm
    definition = TestDefinition.new
    _session, turn = start_session(definition)
    turn.update_columns(attempts: Xeno.config.max_turn_attempts)

    assert_nil turn.claim!
    assert_equal "failed", turn.reload.status
  end

  test "trailing blank assistant rows are cleaned before resuming" do
    start_fake_llm # text "ok"
    definition = TestDefinition.new
    session, turn = start_session(definition)

    # The mid-generate crash artifact from spike #2.
    session.chat.messages_association.create!(role: :assistant, content: "")

    assert_equal :completed, Xeno::TurnRunner.new(turn, definition: definition).run

    roles_and_content = session.chat.messages_association.order(:id).pluck(:role, :content)
    assert_equal [ "system", "user", "assistant" ], roles_and_content.map(&:first)
    assert_equal "ok", roles_and_content.last.last, "the blank artifact must be gone, replaced by a real answer"
  end

  test "unknown tool gets an error result and the turn still completes" do
    start_fake_llm do |body|
      if FakeLLM.tool_result?(body)
        FakeLLM.text("recovered")
      else
        FakeLLM.tool_call("nonexistent", {}, id: "call_rt_missing")
      end
    end
    definition = TestDefinition.new
    session, turn = start_session(definition)

    assert_equal :completed, Xeno::TurnRunner.new(turn, definition: definition).run

    action = turn.actions.sole
    assert_match(/unknown tool/, action.output["content"])
    assert_equal "completed", turn.reload.status
  end
end
