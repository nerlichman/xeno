require "test_helper"

# M2: threshold-triggered summarize-and-replace compaction, executed as a
# claimed turn (kind: "compaction") so it inherits exclusivity, session
# ordering (queues behind active/parked turns), and crash-safe replay.
class CompactionTest < ActiveSupport::TestCase
  include ActiveJob::TestHelper

  class Gated < Xeno::Tool
    description "Needs approval."
    approval :always

    def execute
      { ok: true }
    end
  end

  WINDOW = 1000 # config fallback window; threshold 0.9 → trigger at 900

  setup do
    @old = {
      threshold: Xeno.config.compaction_threshold,
      window: Xeno.config.compaction_context_window,
      tail: Xeno.config.compaction_tail_turns
    }
    Xeno.config.compaction_context_window = WINDOW
    Xeno.config.compaction_tail_turns = 1
  end

  teardown do
    Xeno.config.compaction_threshold = @old[:threshold]
    Xeno.config.compaction_context_window = @old[:window]
    Xeno.config.compaction_tail_turns = @old[:tail]
  end

  def summarizer_request?(body)
    body["messages"].any? { |m| m["role"] == "system" && m["content"].to_s.include?("compacting an agent conversation") }
  end

  # The standard fake: summarizer calls get a canned summary carrying the
  # pre-compaction fact; ordinary turns answer, with controllable usage.
  def start_compaction_fake(&turn_script)
    start_fake_llm do |body|
      if summarizer_request?(body)
        FakeLLM.text("Earlier conversation: the user's favorite color is BLUE; a $42 charge completed.")
      else
        turn_script.call(body)
      end
    end
  end

  def run_next_turn(session, definition)
    turn = session.turns.order(:sequence).last
    [ Xeno::TurnRunner.new(turn, definition: definition).run, turn ]
  end

  test "crossing the threshold stages a compaction turn; it summarizes-and-replaces and later turns still know the facts" do
    fake = start_compaction_fake do |body|
      question = FakeLLM.last_user_content(body).to_s
      if question.include?("favorite color")
        FakeLLM.text("Your favorite color is BLUE.")
      elsif question.include?("second")
        FakeLLM.text("noted the second thing", usage: { prompt: 900, completion: 40 }) # crosses 0.9 * 1000
      else
        FakeLLM.text("hello!", usage: { prompt: 100, completion: 10 })
      end
    end
    definition = TestDefinition.new
    session = Xeno::Session.open!(message: "Remember: my favorite color is blue.", definition: definition)
    assert_equal :completed, run_next_turn(session, definition).first

    # Turn 2 crosses the threshold → a compaction turn is staged behind it.
    session.receive_message!("here is a second message")
    assert_equal :completed, run_next_turn(session, definition).first
    compaction_turn = session.turns.order(:sequence).last
    assert_equal "compaction", compaction_turn.kind
    requested = session.events.where(event_type: "compaction.requested").sole
    assert_equal "auto", requested.data["reason"]
    assert_equal 940, requested.data["used"]
    assert_equal WINDOW, requested.data["limit"]

    # It runs like any turn (claim, fenced writes) and rewrites the transcript.
    assert_equal :completed, Xeno::TurnRunner.new(compaction_turn, definition: definition).run
    assert_equal "completed", compaction_turn.reload.status

    rows = session.chat.reload.messages_association.order(:id).to_a
    assert_equal 1, rows.count { |r| r.role == "system" }, "the system prompt survives"
    convo = rows.reject { |r| r.role == "system" }
    summary_row = convo.first
    assert_equal "user", summary_row.role
    assert_includes summary_row.content, "favorite color is BLUE"
    assert_includes summary_row.content, Xeno::Compaction::SUMMARY_PREFIX
    tail_contents = convo[1..].map(&:content)
    assert_includes tail_contents, "here is a second message", "the recent tail survives verbatim"
    refute rows.any? { |r| r.content == "Remember: my favorite color is blue." },
      "the compacted originals are gone"
    completed = session.events.where(event_type: "compaction.completed").sole
    assert_operator completed.data["compacted_messages"], :>=, 2

    # A later turn answers from the summary — the fact survived compaction.
    session.receive_message!("what is my favorite color?")
    assert_equal :completed, run_next_turn(session, definition).first
    assert_equal "Your favorite color is BLUE.",
      session.chat.messages_association.order(:id).last.content
    final_request = fake.requests.last
    assert final_request["messages"].any? { |m| m["content"].to_s.include?("favorite color is BLUE") },
      "the model saw the summary in place of the compacted history"
  end

  test "park -> approve -> resume still works after a compaction" do
    start_compaction_fake do |body|
      if FakeLLM.tool_result_in_current_turn?(body)
        FakeLLM.text("gated thing done")
      elsif FakeLLM.last_user_content(body).to_s.include?("gated")
        FakeLLM.tool_call("gated", {}, id: "call_compact_gate_#{SecureRandom.hex(4)}")
      else
        FakeLLM.text("ok", usage: { prompt: 100, completion: 10 })
      end
    end
    definition = TestDefinition.new(tools: { "gated" => Gated })
    session = Xeno::Session.open!(message: "first", definition: definition)
    run_next_turn(session, definition)
    session.receive_message!("second")
    run_next_turn(session, definition)

    # Manual compaction between turns.
    compaction_turn = session.stage_compaction_turn!(reason: "manual")
    assert_equal :completed, Xeno::TurnRunner.new(compaction_turn, definition: definition).run
    assert_equal 1, session.events.where(event_type: "compaction.completed").count

    # The parked arc, on the compacted transcript.
    session.receive_message!("do the gated thing")
    result, turn = run_next_turn(session, definition)
    assert_equal :parked, result
    Xeno::Inputs.approve!(turn.reload.actions.sole)
    assert_equal :completed, Xeno::TurnRunner.new(Xeno::Turn.find(turn.id), definition: definition).run
    assert_equal "gated thing done", session.chat.messages_association.order(:id).last.content
  end

  test "a compaction turn queues behind a parked turn and runs after it resolves" do
    start_compaction_fake do |body|
      if FakeLLM.tool_result_in_current_turn?(body)
        FakeLLM.text("done")
      else
        FakeLLM.tool_call("gated", {}, id: "call_queue_gate_#{SecureRandom.hex(4)}")
      end
    end
    definition = TestDefinition.new(tools: { "gated" => Gated })
    session = Xeno::Session.open!(message: "park me", definition: definition)
    result, turn1 = run_next_turn(session, definition)
    assert_equal :parked, result

    compaction_turn = session.stage_compaction_turn!(reason: "manual")
    assert_nil compaction_turn.claim!, "the parked turn blocks the compaction turn"

    Xeno::Inputs.approve!(turn1.reload.actions.sole)
    assert_equal :completed, Xeno::TurnRunner.new(Xeno::Turn.find(turn1.id), definition: definition).run
    # advance_session chained the compaction turn's job; run it.
    assert_equal :completed, Xeno::TurnRunner.new(Xeno::Turn.find(compaction_turn.id), definition: definition).run
    assert_equal "completed", compaction_turn.reload.status
  end

  test "replay after the apply commit is a no-op (crash-safe idempotency)" do
    start_compaction_fake do |_body|
      FakeLLM.text("ok", usage: { prompt: 100, completion: 10 })
    end
    definition = TestDefinition.new
    session = Xeno::Session.open!(message: "first", definition: definition)
    run_next_turn(session, definition)
    session.receive_message!("second")
    run_next_turn(session, definition)

    compaction_turn = session.stage_compaction_turn!(reason: "manual")
    assert_equal :completed, Xeno::TurnRunner.new(compaction_turn, definition: definition).run
    rows_after = session.chat.reload.messages_association.order(:id).pluck(:content)

    # The crash window: applied + committed, but the turn never completed.
    compaction_turn.reload.update_columns(status: "pending")
    assert_equal :completed, Xeno::TurnRunner.new(Xeno::Turn.find(compaction_turn.id), definition: definition).run

    assert_equal rows_after, session.chat.reload.messages_association.order(:id).pluck(:content),
      "replay must not compact twice"
    assert_equal 1, session.events.where(event_type: "compaction.completed").count
  end

  test "too little history: compaction completes as a recorded no-op" do
    start_compaction_fake { |_body| FakeLLM.text("hi", usage: { prompt: 10, completion: 5 }) }
    definition = TestDefinition.new
    session = Xeno::Session.open!(message: "only turn", definition: definition)
    run_next_turn(session, definition)
    before = session.chat.messages_association.order(:id).pluck(:content)

    compaction_turn = session.stage_compaction_turn!(reason: "manual")
    assert_equal :completed, Xeno::TurnRunner.new(compaction_turn, definition: definition).run

    assert_equal before, session.chat.reload.messages_association.order(:id).pluck(:content)
    assert_equal 0, session.events.where(event_type: "compaction.completed").sole.data["compacted_messages"]
  end

  test "no auto compaction below the threshold, when disabled, or when the window is unknown" do
    start_compaction_fake { |_body| FakeLLM.text("cheap", usage: { prompt: 100, completion: 10 }) }
    definition = TestDefinition.new

    session = Xeno::Session.open!(message: "hello", definition: definition)
    run_next_turn(session, definition)
    assert_empty session.turns.where(kind: "compaction"), "100/1000 is under the threshold"

    # Unknown window (no fallback configured) → never triggers.
    Xeno.config.compaction_context_window = nil
    s2 = Xeno::Session.open!(message: "hello", definition: definition)
    run_next_turn(s2, definition)
    assert_empty s2.turns.where(kind: "compaction")

    # Disabled entirely.
    Xeno.config.compaction_context_window = 50 # would trigger...
    Xeno.config.compaction_threshold = nil     # ...but compaction is off
    s3 = Xeno::Session.open!(message: "hello", definition: definition)
    run_next_turn(s3, definition)
    assert_empty s3.turns.where(kind: "compaction")
  end
end

# The manual trigger over HTTP.
class CompactionHttpTest < ActionDispatch::IntegrationTest
  include ActiveJob::TestHelper

  setup do
    Xeno.config.authenticate = ->(request) do
      request.headers["Authorization"] == "Bearer test-key" && { "user" => "api-client" }
    end
    @old_window = Xeno.config.compaction_context_window
    @old_tail = Xeno.config.compaction_tail_turns
    Xeno.config.compaction_tail_turns = 1
  end

  teardown do
    Xeno.config.authenticate = nil
    Xeno.config.compaction_context_window = @old_window
    Xeno.config.compaction_tail_turns = @old_tail
  end

  AUTH = { "Authorization" => "Bearer test-key" }.freeze

  test "POST /compact stages a compaction turn, 409s a duplicate, and the queue runs it" do
    start_fake_llm do |body|
      if body["messages"].any? { |m| m["role"] == "system" && m["content"].to_s.include?("compacting an agent") }
        FakeLLM.text("summary of everything so far")
      else
        FakeLLM.text("answered")
      end
    end

    post "/agent/v1/sessions", params: { message: "one" }, as: :json, headers: AUTH
    session = Xeno::Session.find(JSON.parse(response.body)["session_id"])
    token = JSON.parse(response.body)["continuation_token"]
    perform_enqueued_jobs
    post "/agent/v1/sessions/#{session.id}/messages",
      params: { message: "two", continuation_token: token }, as: :json, headers: AUTH
    perform_enqueued_jobs

    post "/agent/v1/sessions/#{session.id}/compact", headers: AUTH
    assert_response :accepted
    turn_id = JSON.parse(response.body)["turn_id"]
    assert_equal "compaction", Xeno::Turn.find(turn_id).kind
    assert_nil Xeno::Turn.find(turn_id).user_message["compaction"]["used"],
      "manual requests carry no usage numbers"

    post "/agent/v1/sessions/#{session.id}/compact", headers: AUTH
    assert_response :conflict

    perform_enqueued_jobs
    assert_equal "completed", Xeno::Turn.find(turn_id).status
    summary_row = session.chat.messages_association.order(:id).reject { |r| r.role == "system" }.first
    assert_includes summary_row.content, "summary of everything"
  end
end
