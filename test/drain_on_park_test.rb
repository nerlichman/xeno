require "test_helper"

# M1(c): drain-on-park — mvp-design's delivery semantics. Messages queued
# behind a turn become a VISIBLE staged turn the moment the session parks
# (and messages sent to an already-parked session stage immediately),
# instead of sitting invisible until a human resolves the input. The staged
# turn defers its transcript: user rows are written only when the runner
# claims it, so the parked turn's unanswered tool calls stay adjacent to
# their eventual results and every request stays provider-legal.
class DrainOnParkTest < ActiveSupport::TestCase
  include ActiveJob::TestHelper

  class Gated < Xeno::Tool
    description "Needs approval."
    approval :always

    def execute
      { ok: true }
    end
  end

  def park_with_fake
    @fake = start_fake_llm do |body|
      if FakeLLM.tool_result_in_current_turn?(body)
        FakeLLM.text("resumed and done")
      elsif FakeLLM.last_user_content(body).to_s.start_with?("Please")
        FakeLLM.tool_call("gated", {}, id: "call_drain_#{SecureRandom.hex(4)}")
      else
        FakeLLM.text("answer to: #{FakeLLM.last_user_content(body)}")
      end
    end
    definition = TestDefinition.new(tools: { "gated" => Gated })
    session = Xeno::Session.open!(message: "Please do the gated thing", definition: definition)
    [ session, session.turns.order(:sequence).last, definition ]
  end

  test "messages queued mid-turn become a staged turn at park; transcript stays untouched until it runs" do
    session, turn1, definition = park_with_fake

    assert_nil session.receive_message!("queued mid-turn")
    assert_equal 1, session.pending_messages.count

    assert_equal :parked, Xeno::TurnRunner.new(turn1, definition: definition).run

    # Visible NOW: the queued message is a real staged turn...
    assert_equal 0, session.pending_messages.count, "the queue drained at park"
    turn2 = session.turns.order(:sequence).last
    assert_equal 2, turn2.sequence
    assert_equal [ "queued mid-turn" ], turn2.user_message["contents"]
    assert turn2.transcript_deferred?, "the drained turn must not touch a mid-flight transcript"

    # ...but the parked transcript was not mutated (no user row after the
    # assistant's unanswered tool call).
    last_row = session.chat.messages_association.order(:id).last
    assert_equal "assistant", last_row.role
    assert_nil turn2.claim!, "turn order still holds: the parked turn blocks the drained one"

    # Resolve the park; turn 1 completes and chains turn 2, which stages its
    # transcript at claim time and answers on a provider-legal history.
    Xeno::Inputs.approve!(turn1.reload.actions.sole)
    assert_equal :completed, Xeno::TurnRunner.new(Xeno::Turn.find(turn1.id), definition: definition).run
    assert_equal :completed, Xeno::TurnRunner.new(Xeno::Turn.find(turn2.id), definition: definition).run

    refute Xeno::Turn.find(turn2.id).transcript_deferred?
    assert_equal "answer to: queued mid-turn",
      session.chat.messages_association.order(:id).last.content
    assert @fake.requests.all? { |r| FakeLLM.well_formed_tool_calls?(r) },
      "every request during park/drain/resume is provider-legal"
  end

  test "a message sent to an already-parked session stages a visible turn immediately" do
    session, turn1, definition = park_with_fake
    assert_equal :parked, Xeno::TurnRunner.new(turn1, definition: definition).run
    assert_equal 1, session.turns.count, "nothing was queued before the park"

    assert_nil session.reload.receive_message!("hello, while parked")

    assert_equal 0, session.pending_messages.count
    turn2 = session.turns.order(:sequence).last
    assert_equal [ "hello, while parked" ], turn2.user_message["contents"]
    assert turn2.transcript_deferred?
    queued_event = session.events.where(event_type: "message.received").order(:index).last
    assert queued_event.data["queued"]
  end

  test "everything queued at park time folds into ONE staged turn" do
    session, turn1, definition = park_with_fake
    session.receive_message!("two")
    session.receive_message!("three")

    assert_equal :parked, Xeno::TurnRunner.new(turn1, definition: definition).run

    assert_equal 2, session.turns.count, "one drained turn for both messages"
    turn2 = session.turns.order(:sequence).last
    assert_equal %w[two three], turn2.user_message["contents"]
  end

  test "deferred staging is crash-safe: a transient failure after staging never double-adds the user rows" do
    # RubyLLM retries 5xx internally; turn retries are what's under test.
    old_retries = RubyLLM.config.max_retries
    RubyLLM.config.max_retries = 0

    boom = true
    @fake = start_fake_llm do |body|
      if FakeLLM.last_user_content(body) == "drained" && boom
        boom = false
        raise "transient provider failure"
      else
        FakeLLM.text("ok")
      end
    end
    definition = TestDefinition.new
    session = Xeno::Session.open!(message: "first", definition: definition)
    assert_equal :completed, Xeno::TurnRunner.new(session.turns.sole, definition: definition).run

    # A drained (deferred) turn whose first model call blows up transiently.
    session.pending_messages.create!(payload: { "content" => "drained" })
    turn2 = session.drain_pending_messages!(definition: definition)
    assert turn2.transcript_deferred?

    assert_raises(StandardError) { Xeno::TurnRunner.new(turn2, definition: definition).run }
    assert_equal "pending", turn2.reload.status, "released for retry"
    refute turn2.transcript_deferred?, "the transcript staged before the failure"

    # The retry replays: no second copy of the user message.
    assert_equal :completed, Xeno::TurnRunner.new(Xeno::Turn.find(turn2.id), definition: definition).run
    drained_rows = session.chat.messages_association.where(role: "user", content: "drained")
    assert_equal 1, drained_rows.count, "deferred staging must be exactly-once"
  ensure
    RubyLLM.config.max_retries = old_retries if old_retries
  end
end
