# frozen_string_literal: true

require "test_helper"

# the session-scoped KV store — typed (JSON) values, accessible from
# tool code, persisted (survives restarts; the kill -9 proof lives in
# park_kill_resume_test), never crossing sessions, cleared by reset.
class SessionStateTest < ActiveSupport::TestCase
  class Counter < Xeno::Tool
    description "Counts its own invocations in session state."

    def execute
      count = state.get("count").to_i + 1
      state.update("count" => count, "last_note" => "run ##{count}")
      { count: count }
    end
  end

  def run_turn(session, definition)
    Xeno::TurnRunner.new(session.turns.order(:sequence).last, definition: definition).run
  end

  def counting_fake
    start_fake_llm do |body|
      if FakeLLM.tool_result_in_current_turn?(body)
        FakeLLM.text("counted")
      else
        FakeLLM.tool_call("counter", {}, id: "call_state_#{SecureRandom.hex(4)}")
      end
    end
  end

  test "tools read and write state, and it accumulates across turns" do
    counting_fake
    definition = TestDefinition.new(tools: { "counter" => Counter })
    session = Xeno::Session.open!(message: "count", definition: definition)
    assert_equal :completed, run_turn(session, definition)
    session.stage_turn!("count again", definition: definition)
    assert_equal :completed, run_turn(session, definition)

    assert_equal 2, session.state.get("count")
    assert_equal "run #2", session.state.get("last_note")
    # A fresh record (new process, new worker) sees the same rows.
    assert_equal 2, Xeno::Session.find(session.id).state.get("count")
  end

  test "state never crosses sessions" do
    counting_fake
    definition = TestDefinition.new(tools: { "counter" => Counter })
    one = Xeno::Session.open!(message: "count", definition: definition)
    two = Xeno::Session.open!(message: "count", definition: definition)
    run_turn(one, definition)
    run_turn(two, definition)

    assert_equal 1, one.state.get("count")
    assert_equal 1, two.state.get("count")
    one.state.update("only" => "mine")
    assert_nil two.state.get("only")
  end

  test "values are JSON-typed: symbols stringify, unserializable values are rejected up front" do
    definition = TestDefinition.new
    start_fake_llm
    session = Xeno::Session.open!(message: "hi", definition: definition)

    session.state.update(preferences: { theme: :dark }, tags: [ 1, "two" ])
    assert_equal({ "theme" => "dark" }, session.state.get("preferences"))
    assert_equal [ 1, "two" ], session.state["tags"]

    unserializable = Object.new
    def unserializable.to_json(*) = raise(TypeError, "nope")
    error = assert_raises(Xeno::Error) { session.state.set("bad", unserializable) }
    assert_match(/JSON-serializable/, error.message)
    assert_nil session.state.get("bad"), "a rejected write leaves no partial state"
  end

  test "update merges, set and delete work, reset clears everything" do
    definition = TestDefinition.new
    start_fake_llm
    session = Xeno::Session.open!(message: "hi", definition: definition)

    session.state.update("a" => 1)
    session.state.update("b" => 2)
    assert_equal({ "a" => 1, "b" => 2 }, session.state.to_h)
    session.state.delete("a")
    assert_equal({ "b" => 2 }, session.state.to_h)

    session.finish!("completed") # what reset does
    assert_equal({}, Xeno::Session.find(session.id).state.to_h, "reset clears working state")
  end

  test "state outside a session raises a clear error" do
    tool = Counter.new
    error = assert_raises(Xeno::Error) { tool.state }
    assert_match(/inside a session/, error.message)
  end
end
