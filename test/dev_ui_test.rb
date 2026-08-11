# frozen_string_literal: true

require "test_helper"

class DevUiTest < ActionDispatch::IntegrationTest
  include ActiveJob::TestHelper

  setup do
    ENV["XENO_DEV_ROUTES"] = "1"
  end

  teardown do
    ENV.delete("XENO_DEV_ROUTES")
  end

  test "hidden outside development" do
    ENV.delete("XENO_DEV_ROUTES")
    get "/agent/dev"
    assert_response :not_found
  end

  test "chat arc: create, park, approve from the UI, reply" do
    start_fake_llm do |body|
      if FakeLLM.tool_result_in_current_turn?(body)
        FakeLLM.text("charged!")
      elsif FakeLLM.last_user_content(body).to_s.include?("charge")
        FakeLLM.tool_call("charge_card", { amount_cents: 100 }, id: "call_devui_#{FakeLLM.tool_result_count(body)}")
      else
        FakeLLM.text("hello from the fake")
      end
    end

    get "/agent/dev"
    assert_response :success
    # (No emptiness assertion: the shared test DB may carry committed rows
    # from the non-transactional kill/demo tests.)

    # New chat that parks on the gated dummy tool.
    perform_enqueued_jobs do
      post "/agent/dev/sessions", params: { message: "charge me please" }
    end
    session = Xeno::Session.order(:id).last
    follow_redirect!
    assert_response :success
    assert_match(/waiting on you/, response.body)
    assert_match(/charge_card/, response.body)
    assert_match(/Approve/, response.body)

    # Approve from the UI.
    action = Xeno::Action.joins(:turn).where(xeno_turns: { session_id: session.id }).sole
    perform_enqueued_jobs do
      post "/agent/dev/sessions/#{session.id}/inputs",
        params: { action_id: action.id, decision: "approve" }
    end
    follow_redirect!
    assert_match(/charged!/, response.body)
    refute_match(/waiting on you/, response.body)

    # Follow-up message from the reply box.
    perform_enqueued_jobs do
      post "/agent/dev/sessions/#{session.id}/messages", params: { message: "thanks" }
    end
    follow_redirect!
    assert_match(/hello from the fake/, response.body)

    # The index lists it.
    get "/agent/dev"
    assert_match(/session/, response.body)
    assert_match(/open/, response.body)
  end

  test "question actions render an answer box" do
    start_fake_llm do |body|
      if FakeLLM.tool_result?(body)
        FakeLLM.text("noted")
      else
        FakeLLM.tool_call("ask_question", { question: "Which color?" }, id: "call_devui_q")
      end
    end

    perform_enqueued_jobs do
      post "/agent/dev/sessions", params: { message: "pick a color" }
    end
    session = Xeno::Session.order(:id).last
    get "/agent/dev/sessions/#{session.id}"
    assert_match(/Which color\?/, response.body)
    assert_match(/Answer/, response.body)

    action = Xeno::Action.joins(:turn).where(xeno_turns: { session_id: session.id }).sole
    perform_enqueued_jobs do
      post "/agent/dev/sessions/#{session.id}/inputs",
        params: { action_id: action.id, answer: "blue" }
    end
    follow_redirect!
    assert_match(/noted/, response.body)
  end
end
