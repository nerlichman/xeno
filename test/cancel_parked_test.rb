require "test_helper"

# H1 regression: cancelling a parked turn used to leave the assistant
# tool_call rows unanswered forever — every later generate replayed the
# malformed transcript (a provider 400 on every subsequent turn), bricking
# the session. Settlement injects a tool result for every dangling call
# BEFORE the turn dies, so a cancelled-parked session can keep chatting.
class CancelParkedTest < ActionDispatch::IntegrationTest
  include ActiveJob::TestHelper

  setup do
    Xeno.config.authenticate = ->(request) do
      request.headers["Authorization"] == "Bearer test-key" && { "user" => "api-client" }
    end
  end

  teardown do
    Xeno.config.authenticate = nil
  end

  AUTH = { "Authorization" => "Bearer test-key" }.freeze

  def json
    JSON.parse(response.body)
  end

  test "cancel while parked settles the transcript and the session keeps chatting" do
    fake = start_fake_llm do |body|
      if FakeLLM.tool_result_in_current_turn?(body)
        FakeLLM.text("should not happen — turn was cancelled")
      elsif FakeLLM.last_user_content(body) == "still there?"
        FakeLLM.text("yes, still here")
      else
        FakeLLM.tool_call("charge_card", { amount_cents: 4200 }, id: "call_cancel_park")
      end
    end

    perform_enqueued_jobs do
      post "/agent/v1/sessions", params: { message: "charge me" }, as: :json, headers: AUTH
    end
    session = Xeno::Session.find(json["session_id"])
    token = json["continuation_token"]
    assert_equal "waiting", session.reload.status

    post "/agent/v1/sessions/#{session.id}/cancel", headers: AUTH
    assert_response :success

    turn = session.turns.sole
    assert_equal "cancelled", turn.reload.status
    assert_equal "denied", turn.actions.sole.status

    # The dangling call must be answered IN PLACE (before any later message).
    tool_row = session.chat.messages_association.where(role: "tool").sole
    assert_match(/denied/, tool_row.content)
    assert_match(/cancelled by user/, tool_row.content)

    # The bricked-session symptom: the next turn must complete, and the
    # request the provider sees must be well-formed (every assistant
    # tool_calls message immediately followed by its results).
    perform_enqueued_jobs do
      post "/agent/v1/sessions/#{session.id}/messages",
        params: { message: "still there?", continuation_token: token }, as: :json, headers: AUTH
    end
    assert_response :accepted

    follow_up = session.turns.order(:sequence).last
    assert_equal "completed", follow_up.reload.status
    assert_equal "yes, still here", session.chat.messages_association.order(:id).last.content
    assert fake.requests.all? { |body| FakeLLM.well_formed_tool_calls?(body) },
           "cancel left unanswered tool_calls in the transcript (provider would 400)"
  end

  test "schedule park failure settles the transcript for later messages" do
    fake = start_fake_llm do |body|
      if FakeLLM.last_user_content(body) == "follow up"
        FakeLLM.text("recovered")
      else
        FakeLLM.tool_call("charge_card", { amount_cents: 1 }, id: "call_sched_settle")
      end
    end
    definition = Xeno.definition
    session = Xeno::Session.open!(
      message: "do the gated thing", channel: "schedule",
      principal: { "type" => "app" }, definition: definition
    )

    assert_equal :failed, Xeno::TurnRunner.new(session.turns.sole, definition: definition).run

    tool_row = session.chat.messages_association.where(role: "tool").sole
    assert_match(/cannot wait for human input/, tool_row.content)

    follow_up = session.reload.stage_turn!("follow up", definition: definition)
    assert_equal :completed, Xeno::TurnRunner.new(follow_up, definition: definition).run
    assert fake.requests.all? { |body| FakeLLM.well_formed_tool_calls?(body) },
           "schedule park failure left unanswered tool_calls in the transcript"
  end

  test "cancel after an answered question injects the recorded answer, not a denial" do
    start_fake_llm do |body|
      FakeLLM.tool_call("ask_question", { question: "Which day?" }, id: "call_q_cancel")
    end
    definition = Xeno.definition
    session = Xeno::Session.open!(message: "book it", definition: definition)
    turn = session.turns.sole
    assert_equal :parked, Xeno::TurnRunner.new(turn, definition: definition).run

    # Answer the question but cancel before the resume job runs.
    action = turn.actions.sole
    Xeno::Inputs.answer!(action, "Tuesday")
    session.settle_unanswered_tool_calls!(turn, reason: "cancelled by user")

    assert_equal "completed", action.reload.status, "an answered question stays completed"
    tool_row = session.chat.messages_association.where(role: "tool").sole
    assert_match(/Tuesday/, tool_row.content)
  end
end
