require "test_helper"

# H2 regression: `attempts` used to count every claim — including approval
# resumes — so the 5th approval on one turn tripped the poison branch,
# failed the turn AND finished the whole session. Attempts now counts only
# failures (transient errors, crash reclaims); resumes are counted apart
# and are unbounded.
class AttemptsResumesTest < ActiveSupport::TestCase
  include ActiveJob::TestHelper

  def start_session(definition, message: "go")
    session = Xeno::Session.open!(message: message, definition: definition)
    [ session, session.turns.order(:sequence).last ]
  end

  test "a turn survives more approval resumes than max_turn_attempts" do
    cycles = Xeno.config.max_turn_attempts + 2 # 7 with the default of 5
    start_fake_llm do |body|
      answered = FakeLLM.tool_result_count(body)
      if answered >= cycles
        FakeLLM.text("all questions answered")
      else
        FakeLLM.tool_call("ask_question", { question: "q#{answered + 1}?" }, id: "call_h2_q#{answered + 1}")
      end
    end
    definition = TestDefinition.new
    session, turn = start_session(definition)

    cycles.times do |i|
      result = Xeno::TurnRunner.new(turn.reload, definition: definition).run
      assert_equal :parked, result, "cycle #{i + 1} must park, not fail"
      Xeno::Inputs.answer!(turn.actions.order(:id).last, "answer #{i + 1}")
    end
    assert_equal :completed, Xeno::TurnRunner.new(turn.reload, definition: definition).run

    turn.reload
    assert_equal "completed", turn.status
    assert_equal cycles, turn.resumes
    assert_equal 0, turn.attempts, "resumes must not count against the failure ladder"
    assert_equal "all questions answered", session.chat.messages_association.order(:id).last.content
  end

  test "genuine poison turns still fail after max_turn_attempts failures" do
    start_fake_llm
    definition = TestDefinition.new
    session, turn = start_session(definition)

    Xeno.config.max_turn_attempts.times do |i|
      token = turn.reload.claim!
      assert token, "failure #{i + 1}: turn must still be claimable"
      turn.release_for_retry!(token, RuntimeError.new("boom #{i + 1}"))
    end

    assert_equal Xeno.config.max_turn_attempts, turn.reload.attempts
    assert_nil turn.claim!, "poisoned turn must not be claimable"
    assert_equal "failed", turn.reload.status
    assert_match(/max attempts/, turn.error["message"])
    assert_includes session.events.pluck(:event_type), "turn.failed"
    assert_equal "running", session.reload.status,
                 "a poisoned TURN leaves the SESSION running (M3 decision)"
  end

  test "a stale-running reclaim counts as a failure; a pending claim does not" do
    start_fake_llm
    definition = TestDefinition.new
    _session, turn = start_session(definition)

    turn.claim!
    assert_equal 0, turn.reload.attempts, "a clean first claim is not a failure"

    turn.update_columns(heartbeat_at: 1.hour.ago) # owner died silently
    assert Xeno::Turn.find(turn.id).claim!
    assert_equal 1, turn.reload.attempts, "crash evidence (stale reclaim) counts"
  end
end
