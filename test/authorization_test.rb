require "test_helper"

# H4 regression: per-principal authorization. The principal was stamped on
# sessions but never checked — any authenticated caller could approve any
# session's pending tool call, cancel/reset any session, and read any
# session's stream (IDOR). Ownership rule: a session belongs to the
# principal stamped at create; a non-matching caller gets the same 404 as a
# nonexistent id. Client-supplied continuation tokens are restricted to the
# reserved http: namespace; token comparison is timing-safe.
class AuthorizationTest < ActionDispatch::IntegrationTest
  include ActiveJob::TestHelper

  setup do
    Xeno.config.authenticate = ->(request) do
      key = request.headers["Authorization"].to_s.delete_prefix("Bearer ")
      { "alice" => { "user" => "alice" }, "mallory" => { "user" => "mallory" } }[key]
    end
  end

  teardown do
    Xeno.config.authenticate = nil
  end

  ALICE = { "Authorization" => "Bearer alice" }.freeze
  MALLORY = { "Authorization" => "Bearer mallory" }.freeze

  def json
    JSON.parse(response.body)
  end

  # A session owned by alice, parked on the gated charge_card tool.
  def park_as_alice
    start_fake_llm do |body|
      if FakeLLM.tool_result?(body)
        FakeLLM.text("charged!")
      else
        FakeLLM.tool_call("charge_card", { amount_cents: 500 }, id: "call_authz")
      end
    end
    perform_enqueued_jobs do
      post "/agent/v1/sessions", params: { message: "charge me" }, as: :json, headers: ALICE
    end
    session = Xeno::Session.find(json["session_id"])
    [ session, json["continuation_token"] ]
  end

  test "another principal cannot approve, cancel, reset, or stream a session" do
    session, _token = park_as_alice
    action_id = session.events.find_by(event_type: "input.requested").data["action_id"]

    post "/agent/v1/sessions/#{session.id}/inputs",
      params: { action_id: action_id, decision: "approve" }, as: :json, headers: MALLORY
    assert_response :not_found
    assert_equal "pending_approval", Xeno::Action.find(action_id).status,
                 "a cross-principal approve must not resolve the action"

    post "/agent/v1/sessions/#{session.id}/cancel", headers: MALLORY
    assert_response :not_found
    assert_equal "waiting", session.reload.status

    post "/agent/v1/sessions/#{session.id}/reset", headers: MALLORY
    assert_response :not_found
    assert session.reload.active?, "a cross-principal reset must not retire the session"

    get "/agent/v1/sessions/#{session.id}/stream", headers: MALLORY
    assert_response :not_found
  end

  test "another principal cannot message a session even with the right token" do
    session, token = park_as_alice

    post "/agent/v1/sessions/#{session.id}/messages",
      params: { message: "hijack", continuation_token: token }, as: :json, headers: MALLORY
    assert_response :not_found
    assert_empty session.pending_messages, "the hijack message must not be queued"
  end

  test "the owning principal passes all the same checks" do
    session, _token = park_as_alice
    action_id = session.events.find_by(event_type: "input.requested").data["action_id"]

    perform_enqueued_jobs do
      post "/agent/v1/sessions/#{session.id}/inputs",
        params: { action_id: action_id, decision: "approve" }, as: :json, headers: ALICE
    end
    assert_response :success
    assert_equal "completed", session.turns.sole.reload.status
  end

  test "client-supplied continuation tokens must use the http: namespace" do
    start_fake_llm

    post "/agent/v1/sessions",
      params: { message: "hi", continuation_token: "slack:C1:99.9" }, as: :json, headers: ALICE
    assert_response :unprocessable_entity
    assert_match(/http: namespace/, json["error"])

    post "/agent/v1/sessions",
      params: { message: "hi", continuation_token: "http:my-key" }, as: :json, headers: ALICE
    assert_response :created
    assert_equal "http:my-key", json["continuation_token"]
  end

  test "token comparison is timing-safe and nil-safe" do
    session, token = park_as_alice

    # Wrong token of a different length must not raise, just 403.
    post "/agent/v1/sessions/#{session.id}/messages",
      params: { message: "x", continuation_token: "short" }, as: :json, headers: ALICE
    assert_response :forbidden

    post "/agent/v1/sessions/#{session.id}/messages",
      params: { message: "x", continuation_token: "" }, as: :json, headers: ALICE
    assert_response :forbidden

    assert token.present?
  end
end
