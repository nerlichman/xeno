# frozen_string_literal: true

require "test_helper"

class PendingMessagesTest < ActiveSupport::TestCase
  include ActiveJob::TestHelper

  test "mid-turn message queues and folds into the next turn" do
    start_fake_llm do |body|
      FakeLLM.text("answer to: #{FakeLLM.last_user_content(body)}")
    end
    definition = TestDefinition.new
    session = Xeno::Session.open!(message: "first", definition: definition)
    turn1 = session.turns.order(:sequence).last

    # A message lands while turn 1 is still active (pending counts: the job
    # hasn't finished). It must queue, not start a competing turn.
    assert_nil session.receive_message!("second (arrived mid-turn)")
    assert_equal 1, session.pending_messages.count
    assert_equal 1, session.turns.count

    queued_event = session.events.where(event_type: "message.received").order(:index).last
    assert queued_event.data["queued"], "queued receipt is visible in the stream"

    # Turn 1 finishes → the queued message drains into turn 2 and its job chains.
    assert_equal :completed, Xeno::TurnRunner.new(turn1, definition: definition).run

    assert_equal 0, session.pending_messages.count
    turn2 = session.turns.order(:sequence).last
    assert_equal 2, turn2.sequence
    assert_equal [ "second (arrived mid-turn)" ], turn2.user_message["contents"]
    assert_enqueued_with(job: Xeno::TurnJob, args: [ turn2.id ])

    # And the folded turn runs normally on the full transcript.
    assert_equal :completed, Xeno::TurnRunner.new(turn2, definition: definition).run
    assert_equal "answer to: second (arrived mid-turn)",
      session.chat.messages_association.order(:id).last.content
  end

  test "multiple queued messages fold into ONE next turn" do
    start_fake_llm do |body|
      FakeLLM.text("got it")
    end
    definition = TestDefinition.new
    session = Xeno::Session.open!(message: "first", definition: definition)
    turn1 = session.turns.order(:sequence).last

    session.receive_message!("two")
    session.receive_message!("three")
    assert_equal 2, session.pending_messages.count

    Xeno::TurnRunner.new(turn1, definition: definition).run

    turn2 = session.turns.order(:sequence).last
    assert_equal 2, session.turns.count, "both messages fold into a single turn"
    assert_equal %w[two three], turn2.user_message["contents"]

    # Drained turns defer their transcript to claim time (M1c); the rows
    # appear once the folded turn actually runs.
    Xeno::TurnRunner.new(turn2, definition: definition).run
    user_rows = session.chat.messages_association.where(role: "user").order(:id).pluck(:content)
    assert_equal [ "first", "two", "three" ], user_rows
  end

  test "message on an idle session starts a turn immediately" do
    start_fake_llm
    definition = TestDefinition.new
    session = Xeno::Session.open!(message: "first", definition: definition)
    Xeno::TurnRunner.new(session.turns.order(:sequence).last, definition: definition).run

    turn = nil
    assert_enqueued_jobs(1, only: Xeno::TurnJob) do
      turn = session.receive_message!("follow-up")
    end
    assert turn.is_a?(Xeno::Turn)
    assert_equal 0, session.pending_messages.count
  end

  test "a later turn cannot claim while an earlier one is active" do
    start_fake_llm
    definition = TestDefinition.new
    session = Xeno::Session.open!(message: "first", definition: definition)
    turn1 = session.turns.order(:sequence).last
    turn2 = session.stage_turn!("second", definition: definition)

    assert_nil turn2.claim!, "turn 2 must wait for turn 1"
    assert turn1.claim!

    # turn 1 (running) still blocks turn 2 until it reaches a terminal status.
    assert_nil turn2.claim!
    turn1.update_columns(status: "completed")
    assert turn2.claim!
  end
end
