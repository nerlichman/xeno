# frozen_string_literal: true

require "test_helper"

# Regression: a raising tool used to bubble into the
# queue's retry ladder — no action row recorded, so every retry re-ran the
# tool (side effects!), and after retry_on exhausted the turn wedged
# pending forever. The exception now becomes an error tool result the
# model recovers from; the failed action row is a checkpoint that replays.
class ToolErrorTest < ActiveSupport::TestCase
  class Explosive < Xeno::Tool
    description "Raises on execute."
    parameter :note, description: "Anything"

    class << self
      attr_accessor :executions
    end

    def execute(note: nil)
      self.class.executions += 1
      raise ArgumentError, "boom from the tool body"
    end
  end

  setup do
    Explosive.executions = 0
  end

  def start_session(definition)
    session = Xeno::Session.open!(message: "go", definition: definition)
    [ session, session.turns.order(:sequence).last ]
  end

  test "a raising tool becomes an error result; the model recovers; no re-execution" do
    start_fake_llm do |body|
      if FakeLLM.tool_result?(body)
        FakeLLM.text("recovered gracefully")
      else
        FakeLLM.tool_call("explosive", { note: "x" }, id: "call_explode")
      end
    end
    definition = TestDefinition.new(tools: { "explosive" => Explosive })
    session, turn = start_session(definition)

    result = Xeno::TurnRunner.new(turn, definition: definition).run

    assert_equal :completed, result, "a tool exception must not escape the runner"
    assert_equal 1, Explosive.executions
    assert_equal "completed", turn.reload.status

    action = turn.actions.sole
    assert_equal "failed", action.status
    assert_match(/boom from the tool body/, action.output["content"])

    tool_row = session.chat.messages_association.where(role: "tool").sole
    assert_match(/explosive raised ArgumentError/, tool_row.content)
    assert_equal "recovered gracefully", session.chat.messages_association.order(:id).last.content

    types = session.events.pluck(:event_type)
    assert_includes types, "step.failed"
    failed_result = session.events.find_by(event_type: "action.result")
    assert_equal "failed", failed_result.data["status"]
  end

  test "a recorded failed action replays without re-executing the tool" do
    start_fake_llm do |body|
      if FakeLLM.tool_result?(body)
        FakeLLM.text("done")
      else
        FakeLLM.tool_call("explosive", { note: "x" }, id: "call_explode_replay")
      end
    end
    definition = TestDefinition.new(tools: { "explosive" => Explosive })
    session, turn = start_session(definition)
    Xeno::TurnRunner.new(turn, definition: definition).run
    assert_equal 1, Explosive.executions

    # Simulate a crash AFTER the failed checkpoint but before the final
    # generate: drop the trailing assistant answer and re-run the turn.
    session.chat.messages_association.order(:id).last.destroy!
    Xeno::Turn.where(id: turn.id).update_all(status: "pending")

    assert_equal :completed, Xeno::TurnRunner.new(turn.reload, definition: definition).run
    assert_equal 1, Explosive.executions, "the failed checkpoint must replay, never re-execute"
  end
end
