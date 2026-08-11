# frozen_string_literal: true

require "test_helper"

# The HTTP channel contract: fail-closed auth, principal stamping, the
# continuation-token lifecycle (unique among active, released on terminal,
# reset lets the same token start fresh), inputs, and cancel.
# Turns run through the real TurnJob (perform_enqueued_jobs) against the
# dummy app's actual agent/ directory.
class HttpChannelTest < ActionDispatch::IntegrationTest
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

  test "everything but health is 401 without credentials; fail-closed without a lambda" do
    get "/agent/v1/health"
    assert_response :success

    post "/agent/v1/sessions", params: { message: "hi" }, as: :json
    assert_response :unauthorized

    Xeno.config.authenticate = nil
    post "/agent/v1/sessions", params: { message: "hi" }, as: :json,
      headers: AUTH
    assert_response :unauthorized, "no configured lambda must mean 401, not open"
  end

  test "create runs a turn end-to-end and stamps the principal" do
    start_fake_llm
    perform_enqueued_jobs do
      post "/agent/v1/sessions", params: { message: "hello" }, as: :json, headers: AUTH
    end

    assert_response :created
    session = Xeno::Session.find(json["session_id"])
    assert json["continuation_token"].start_with?("http:")
    assert_equal({ "user" => "api-client" }, session.principal)
    assert_equal "http", session.channel
    assert_equal "completed", session.turns.sole.status
    assert_equal "ok", session.chat.messages_association.order(:id).last.content
  end

  test "continuation token must be unique among active sessions" do
    start_fake_llm
    post "/agent/v1/sessions",
      params: { message: "one", continuation_token: "http:client-key-1" }, as: :json, headers: AUTH
    assert_response :created

    post "/agent/v1/sessions",
      params: { message: "two", continuation_token: "http:client-key-1" }, as: :json, headers: AUTH
    assert_response :conflict
    assert_match(/already in use/, json["error"])
  end

  test "follow-up messages require the right token; finished sessions are gone" do
    start_fake_llm
    perform_enqueued_jobs do
      post "/agent/v1/sessions", params: { message: "hello" }, as: :json, headers: AUTH
    end
    session_id = json["session_id"]
    token = json["continuation_token"]

    post "/agent/v1/sessions/#{session_id}/messages",
      params: { message: "again", continuation_token: "wrong" }, as: :json, headers: AUTH
    assert_response :forbidden

    perform_enqueued_jobs do
      post "/agent/v1/sessions/#{session_id}/messages",
        params: { message: "again", continuation_token: token }, as: :json, headers: AUTH
    end
    assert_response :accepted
    refute json["queued"]
    assert_equal "completed", Xeno::Turn.find(json["turn_id"]).status

    post "/agent/v1/sessions/#{session_id}/reset", headers: AUTH
    assert_response :success

    post "/agent/v1/sessions/#{session_id}/messages",
      params: { message: "zombie", continuation_token: token }, as: :json, headers: AUTH
    assert_response :gone
  end

  test "approval flow over HTTP: park, approve, resume to completion" do
    start_fake_llm do |body|
      if FakeLLM.tool_result?(body)
        FakeLLM.text("charged!")
      else
        FakeLLM.tool_call("charge_card", { amount_cents: 500 }, id: "call_http_charge")
      end
    end

    perform_enqueued_jobs do
      post "/agent/v1/sessions", params: { message: "charge me" }, as: :json, headers: AUTH
    end
    session = Xeno::Session.find(json["session_id"])
    assert_equal "waiting", session.reload.status

    event = session.events.find_by(event_type: "input.requested")
    action_id = event.data["action_id"]

    perform_enqueued_jobs do
      post "/agent/v1/sessions/#{session.id}/inputs",
        params: { action_id: action_id, decision: "approve" }, as: :json, headers: AUTH
    end
    assert_response :success

    assert_equal "completed", session.turns.sole.reload.status
    assert_equal "charged!", session.chat.messages_association.order(:id).last.content
    assert_equal({ "user" => "api-client" }, Xeno::Action.find(action_id).resolved_by)
  end

  test "question flow over HTTP: park, answer, resume" do
    start_fake_llm do |body|
      if FakeLLM.tool_result?(body)
        answer = JSON.parse(body["messages"].find { |m| m["role"] == "tool" }["content"])["answer"]
        FakeLLM.text("noted: #{answer}")
      else
        FakeLLM.tool_call("ask_question", { question: "Which env?" }, id: "call_http_q")
      end
    end

    perform_enqueued_jobs do
      post "/agent/v1/sessions", params: { message: "deploy" }, as: :json, headers: AUTH
    end
    session = Xeno::Session.find(json["session_id"])
    action_id = session.events.find_by(event_type: "input.requested").data["action_id"]

    perform_enqueued_jobs do
      post "/agent/v1/sessions/#{session.id}/inputs",
        params: { action_id: action_id, answer: "staging" }, as: :json, headers: AUTH
    end
    assert_response :success
    assert_equal "noted: staging", session.chat.messages_association.order(:id).last.content
  end

  test "deny flow over HTTP" do
    start_fake_llm do |body|
      if FakeLLM.tool_result?(body)
        FakeLLM.text("understood, not charging")
      else
        FakeLLM.tool_call("charge_card", { amount_cents: 999_99 }, id: "call_http_deny")
      end
    end

    perform_enqueued_jobs do
      post "/agent/v1/sessions", params: { message: "charge a lot" }, as: :json, headers: AUTH
    end
    session = Xeno::Session.find(json["session_id"])
    action_id = session.events.find_by(event_type: "input.requested").data["action_id"]

    perform_enqueued_jobs do
      post "/agent/v1/sessions/#{session.id}/inputs",
        params: { action_id: action_id, decision: "deny", reason: "nope" }, as: :json, headers: AUTH
    end
    assert_response :success
    assert_equal "denied", Xeno::Action.find(action_id).status
    assert_equal "understood, not charging", session.chat.messages_association.order(:id).last.content

    # Double resolution is a conflict.
    post "/agent/v1/sessions/#{session.id}/inputs",
      params: { action_id: action_id, decision: "approve" }, as: :json, headers: AUTH
    assert_response :conflict
  end

  test "cancel: parked turn cancels immediately; running turn cancels cooperatively" do
    start_fake_llm do |body|
      if FakeLLM.tool_result?(body)
        FakeLLM.text("done")
      else
        FakeLLM.tool_call("charge_card", { amount_cents: 1 }, id: "call_http_cancel")
      end
    end

    perform_enqueued_jobs do
      post "/agent/v1/sessions", params: { message: "charge" }, as: :json, headers: AUTH
    end
    session = Xeno::Session.find(json["session_id"])
    assert_equal "waiting", session.reload.status

    post "/agent/v1/sessions/#{session.id}/cancel", headers: AUTH
    assert_response :success
    turn = session.turns.sole
    assert_equal "cancelled", turn.reload.status
    assert_equal "running", session.reload.status
    assert_equal "denied", turn.actions.sole.status

    # No active turn now.
    post "/agent/v1/sessions/#{session.id}/cancel", headers: AUTH
    assert_response :conflict

    # Simulate a running turn: cooperative path flips the persisted flag.
    turn2 = session.stage_turn!("another")
    turn2.update_columns(status: "running")
    post "/agent/v1/sessions/#{session.id}/cancel", headers: AUTH
    assert_response :accepted
    assert session.chat.reload.cancelled?, "cooperative cancel is the persisted chats.cancelled bit"
  end

  test "reset releases the token for reuse and audits it" do
    start_fake_llm
    perform_enqueued_jobs do
      post "/agent/v1/sessions",
        params: { message: "one", continuation_token: "http:client-key-9" }, as: :json, headers: AUTH
    end
    first_id = json["session_id"]

    post "/agent/v1/sessions/#{first_id}/reset", headers: AUTH
    assert_response :success
    assert_equal "http:client-key-9", json["released_continuation_token"]

    first = Xeno::Session.find(first_id)
    assert_equal "completed", first.status
    assert_nil first.continuation_token
    assert_equal "http:client-key-9", first.metadata["released_continuation_token"]

    # The same token can start fresh now.
    perform_enqueued_jobs do
      post "/agent/v1/sessions",
        params: { message: "two", continuation_token: "http:client-key-9" }, as: :json, headers: AUTH
    end
    assert_response :created
    refute_equal first_id, json["session_id"]
  end
end
