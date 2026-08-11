# frozen_string_literal: true

require "test_helper"

# steering — opt-in "stop what you're doing, do THIS instead". A parked
# or pending turn settles (H1 machinery) and cancels immediately; a running
# turn cancels cooperatively at the next step boundary with the steer
# message queued to become the next turn; an idle session just gets a turn.
class SteeringTest < ActiveSupport::TestCase
  include ActiveJob::TestHelper

  class Gated < Xeno::Tool
    description "Needs approval."
    approval :always

    def execute
      { ok: true }
    end
  end

  # Steers its own session mid-turn, then outwaits RubyLLM's 1s cancellation
  # poll throttle so the cooperative cancel fires at the NEXT model call.
  class SteeringTool < Xeno::Tool
    description "Triggers a steer from inside the turn."

    cattr_accessor :session_id

    def execute
      Xeno::Session.find(self.class.session_id).steer!("actually, forget that — say STEERED")
      sleep 1.1
      { ok: true }
    end
  end

  test "mid-turn steer: the running turn settles as cancelled and the steer message runs next on the full transcript" do
    fake = start_fake_llm do |body|
      last_user = FakeLLM.last_user_content(body).to_s
      if last_user.include?("say STEERED")
        FakeLLM.text("STEERED, as requested")
      else
        FakeLLM.tool_call("steering_tool", {}, id: "call_steer_#{SecureRandom.hex(4)}")
      end
    end
    definition = TestDefinition.new(tools: { "steering_tool" => SteeringTool })
    session = Xeno::Session.open!(message: "start something long", definition: definition)
    SteeringTool.session_id = session.id
    turn1 = session.turns.sole

    assert_equal :cancelled, Xeno::TurnRunner.new(turn1, definition: definition).run

    assert_equal "cancelled", turn1.reload.status
    steer_receipt = session.events.where(event_type: "message.received").order(:index).last
    assert steer_receipt.data["steer"], "the steer receipt is visible in the stream"

    # The cancel path drained the steer message into the next turn.
    turn2 = session.turns.order(:sequence).last
    refute_equal turn1.id, turn2.id
    assert_equal [ "actually, forget that — say STEERED" ], turn2.user_message["contents"]

    assert_equal :completed, Xeno::TurnRunner.new(turn2, definition: definition).run
    assert_equal "STEERED, as requested", session.chat.messages_association.order(:id).last.content
    assert fake.requests.all? { |r| FakeLLM.well_formed_tool_calls?(r) },
      "the settled transcript stays provider-legal"
  end

  test "parked steer: pending inputs are denied safely, the turn cancels, the steer message runs immediately" do
    fake = start_fake_llm do |body|
      if FakeLLM.last_user_content(body).to_s.include?("do this instead")
        FakeLLM.text("doing the new thing")
      else
        FakeLLM.tool_call("gated", {}, id: "call_steer_park_#{SecureRandom.hex(4)}")
      end
    end
    definition = TestDefinition.new(tools: { "gated" => Gated })
    session = Xeno::Session.open!(message: "park me", definition: definition)
    turn1 = session.turns.sole
    assert_equal :parked, Xeno::TurnRunner.new(turn1, definition: definition).run
    action = turn1.reload.actions.sole

    turn2 = nil
    assert_enqueued_with(job: Xeno::TurnJob) do
      turn2 = session.steer!("do this instead", definition: definition)
    end

    assert_equal "cancelled", turn1.reload.status
    assert_equal "denied", action.reload.status, "the pending approval resolved safely"
    assert_equal "running", session.reload.status

    assert_equal :completed, Xeno::TurnRunner.new(turn2, definition: definition).run
    assert_equal "doing the new thing", session.chat.messages_association.order(:id).last.content
    assert fake.requests.all? { |r| FakeLLM.well_formed_tool_calls?(r) },
      "the denial results settle the dangling tool calls"
  end

  test "pending-turn steer: the staged turn is replaced (its contents stay auditable on the cancelled row)" do
    start_fake_llm { |body| FakeLLM.text("answer to: #{FakeLLM.last_user_content(body)}") }
    definition = TestDefinition.new
    session = Xeno::Session.open!(message: "first", definition: definition)
    Xeno::TurnRunner.new(session.turns.sole, definition: definition).run
    pending = session.stage_turn!("the old plan", definition: definition)

    turn = session.steer!("the new plan", definition: definition)

    assert_equal "cancelled", pending.reload.status
    assert_equal [ "the old plan" ], pending.user_message["contents"], "replaced, but auditable"
    assert_equal :completed, Xeno::TurnRunner.new(turn, definition: definition).run
    assert_equal "answer to: the new plan", session.chat.messages_association.order(:id).last.content
  end

  test "idle steer is just a message" do
    start_fake_llm
    definition = TestDefinition.new
    session = Xeno::Session.open!(message: "first", definition: definition)
    Xeno::TurnRunner.new(session.turns.sole, definition: definition).run

    turn = session.steer!("follow-up", definition: definition)
    assert turn.is_a?(Xeno::Turn)
    assert_equal :completed, Xeno::TurnRunner.new(turn, definition: definition).run
  end
end

# The steer flag over HTTP.
class SteeringHttpTest < ActionDispatch::IntegrationTest
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

  test "steer: true on the message endpoint replaces a parked turn" do
    start_fake_llm do |body|
      if FakeLLM.last_user_content(body).to_s.include?("instead")
        FakeLLM.text("new thing done")
      else
        FakeLLM.tool_call("charge_card", { amount_cents: 4200 }, id: "call_http_steer_#{SecureRandom.hex(4)}")
      end
    end

    post "/agent/v1/sessions", params: { message: "charge me" }, as: :json, headers: AUTH
    body = JSON.parse(response.body)
    session = Xeno::Session.find(body["session_id"])
    perform_enqueued_jobs
    assert_equal "waiting", session.reload.status

    post "/agent/v1/sessions/#{session.id}/messages",
      params: { message: "do the other thing instead", continuation_token: body["continuation_token"], steer: true },
      as: :json, headers: AUTH
    assert_response :accepted
    assert JSON.parse(response.body)["steered"]

    perform_enqueued_jobs
    assert_equal "cancelled", session.turns.order(:sequence).first.reload.status
    assert_equal "new thing done", session.chat.messages_association.order(:id).last.content
  end
end
