# frozen_string_literal: true

require "test_helper"

class ParkingTest < ActiveSupport::TestCase
  include ActiveJob::TestHelper

  class ChargeCard < Xeno::Tool
    description "Charge the card. Irreversible."
    parameter :amount_cents, type: :integer, description: "Amount in cents"
    approval :always

    class << self
      attr_accessor :executions
    end

    def execute(amount_cents:)
      self.class.executions += 1
      { charged: amount_cents, charge_id: "ch_#{amount_cents}" }
    end
  end

  class WireTransfer < Xeno::Tool
    description "Wire funds. Irreversible."
    parameter :amount_cents, type: :integer, description: "Amount in cents"
    requires_approval

    class << self
      attr_accessor :executions
    end

    def execute(amount_cents:)
      self.class.executions += 1
      { wired: amount_cents }
    end
  end

  class SendReport < Xeno::Tool
    description "Send the weekly report."
    approval :once

    class << self
      attr_accessor :executions
    end

    def execute
      self.class.executions += 1
      { sent: true }
    end
  end

  class AdminOnly < Xeno::Tool
    description "Only admins skip approval."
    approval ->(ctx) { ctx.principal&.dig("role") != "admin" }

    def execute
      { done: true }
    end
  end

  class Echo < Xeno::Tool
    description "Echoes."
    parameter :text, description: "Text"

    class << self
      attr_accessor :executions
    end

    def execute(text:)
      self.class.executions += 1
      { echoed: text }
    end
  end

  setup do
    ChargeCard.executions = 0
    SendReport.executions = 0
    Echo.executions = 0
    WireTransfer.executions = 0
  end

  def start_session(definition, message: "go", principal: nil)
    session = Xeno::Session.open!(message: message, principal: principal, definition: definition)
    [ session, session.turns.order(:sequence).last ]
  end

  def charge_script(call_id: "call_park_charge")
    ->(body) do
      if FakeLLM.tool_result?(body)
        FakeLLM.text("charged, all done")
      else
        FakeLLM.tool_call("charge_card", { amount_cents: 4200 }, id: call_id)
      end
    end
  end

  test "RubyLLM's requires_approval gates a tool with no xeno policy" do
    script = ->(body) do
      if FakeLLM.tool_result?(body)
        FakeLLM.text("wired, all done")
      else
        FakeLLM.tool_call("wire_transfer", { amount_cents: 4200 }, id: "call_wire_1")
      end
    end
    start_fake_llm(&script)
    definition = TestDefinition.new(tools: { "wire_transfer" => WireTransfer })
    session, turn = start_session(definition)

    assert_equal :parked, Xeno::TurnRunner.new(turn, definition: definition).run

    assert_equal 0, WireTransfer.executions, "a requires_approval tool must not run ungated"
    assert_equal "pending_approval", turn.actions.sole.status
    assert_equal "waiting", session.reload.status
  end

  test "approval :always parks the turn without executing" do
    start_fake_llm(&charge_script)
    definition = TestDefinition.new(tools: { "charge_card" => ChargeCard })
    session, turn = start_session(definition)

    assert_equal :parked, Xeno::TurnRunner.new(turn, definition: definition).run

    assert_equal 0, ChargeCard.executions, "gated tool must not run before approval"
    assert_equal "waiting", turn.reload.status
    assert_equal "waiting", session.reload.status

    action = turn.actions.sole
    assert_equal "pending_approval", action.status
    assert_equal({ "amount_cents" => 4200 }, action.input)

    event = session.events.find_by(event_type: "input.requested")
    assert event, "input.requested must be emitted"
    assert_equal "charge_card", event.data["tool"]
    assert_equal action.id, event.data["action_id"]
    assert_includes session.events.pluck(:event_type), "session.waiting"
  end

  test "approve resumes through the job and completes; tool runs exactly once" do
    start_fake_llm(&charge_script)
    definition = TestDefinition.new(tools: { "charge_card" => ChargeCard })
    session, turn = start_session(definition)
    Xeno::TurnRunner.new(turn, definition: definition).run

    action = turn.actions.sole
    Xeno::Inputs.approve!(action, principal: { "user" => "nicolas" })

    mirrored = RubyLLM::ActiveRecord::ToolCall.find_by(tool_call_id: action.tool_call_id)
    assert_equal "approved", mirrored.approval, "decision mirrors to the standard column"
    assert_equal "pending", turn.reload.status, "resume flips waiting back to pending"
    assert_equal "running", session.reload.status

    # The resume was enqueued; run it (the job uses the app definition, so
    # drive the runner directly with our test definition instead).
    assert_enqueued_with(job: Xeno::TurnJob, args: [ turn.id ])
    assert_equal :completed, Xeno::TurnRunner.new(turn.reload, definition: definition).run

    assert_equal 1, ChargeCard.executions
    assert_equal "completed", turn.reload.status
    assert_equal "running", session.reload.status
    assert_equal "charged, all done", session.chat.messages_association.order(:id).last.content

    action.reload
    assert_equal "completed", action.status
    assert_equal({ "user" => "nicolas" }, action.resolved_by)
    assert action.resolved_at.present?
  end

  test "deny injects a denial result and the model recovers without execution" do
    start_fake_llm do |body|
      if FakeLLM.tool_result?(body)
        FakeLLM.text("okay, I won't charge you")
      else
        FakeLLM.tool_call("charge_card", { amount_cents: 4200 }, id: "call_park_deny")
      end
    end
    definition = TestDefinition.new(tools: { "charge_card" => ChargeCard })
    session, turn = start_session(definition)
    Xeno::TurnRunner.new(turn, definition: definition).run

    action = turn.actions.sole
    Xeno::Inputs.deny!(action, reason: "too expensive", principal: { "user" => "nicolas" })

    assert_equal :completed, Xeno::TurnRunner.new(turn.reload, definition: definition).run

    assert_equal 0, ChargeCard.executions, "denied tool must never execute"
    assert_equal "denied", action.reload.status
    tool_row = session.chat.messages_association.where(role: "tool").sole
    assert_match(/too expensive/, tool_row.content)
    assert_equal "okay, I won't charge you", session.chat.messages_association.order(:id).last.content
  end

  test "ask_question parks; the answer is injected as the tool result" do
    start_fake_llm do |body|
      if FakeLLM.tool_result?(body)
        answer = JSON.parse(body["messages"].find { |m| m["role"] == "tool" }["content"])["answer"]
        FakeLLM.text("Great, booking for #{answer}.")
      else
        FakeLLM.tool_call("ask_question", { question: "Which day works?", choices: [ "Mon", "Tue" ] },
                          id: "call_park_q")
      end
    end
    definition = TestDefinition.new
    session, turn = start_session(definition)

    assert_equal :parked, Xeno::TurnRunner.new(turn, definition: definition).run

    action = turn.actions.sole
    assert_equal "question", action.kind
    assert_equal "ask_question", action.tool_name
    event = session.events.find_by(event_type: "input.requested")
    assert_equal "Which day works?", event.data.dig("arguments", "question")

    Xeno::Inputs.answer!(action, "Tue")
    assert_equal :completed, Xeno::TurnRunner.new(turn.reload, definition: definition).run

    assert_equal "Great, booking for Tue.", session.chat.messages_association.order(:id).last.content
    assert_equal "completed", turn.reload.status
  end

  test "approval :once asks the first time, remembers for the rest of the session" do
    requests = 0
    start_fake_llm do |body|
      requests += 1
      if FakeLLM.tool_result_in_current_turn?(body)
        FakeLLM.text("sent")
      else
        FakeLLM.tool_call("send_report", {}, id: "call_once_#{requests}")
      end
    end
    definition = TestDefinition.new(tools: { "send_report" => SendReport })
    session, turn1 = start_session(definition)

    assert_equal :parked, Xeno::TurnRunner.new(turn1, definition: definition).run
    Xeno::Inputs.approve!(turn1.actions.sole)
    assert_equal :completed, Xeno::TurnRunner.new(turn1.reload, definition: definition).run
    assert_equal 1, SendReport.executions

    # Second turn, same session: no park this time.
    turn2 = session.reload.stage_turn!("send it again", definition: definition)
    assert_equal :completed, Xeno::TurnRunner.new(turn2, definition: definition).run
    assert_equal 2, SendReport.executions
    assert_equal "completed", turn2.reload.status
  end

  test "lambda approval consults the principal" do
    script = ->(body) do
      if FakeLLM.tool_result?(body)
        FakeLLM.text("done")
      else
        FakeLLM.tool_call("admin_only", {}, id: "call_lambda_#{FakeLLM.tool_result_count(body)}_#{rand(10_000)}")
      end
    end
    definition = TestDefinition.new(tools: { "admin_only" => AdminOnly })

    start_fake_llm(&script)
    _session, admin_turn = start_session(definition, principal: { "role" => "admin" })
    assert_equal :completed, Xeno::TurnRunner.new(admin_turn, definition: definition).run

    _session, guest_turn = start_session(definition, principal: { "role" => "guest" })
    assert_equal :parked, Xeno::TurnRunner.new(guest_turn, definition: definition).run
  end

  test "mixed batch: ungated executes, gated parks, resume replays without re-running" do
    start_fake_llm do |body|
      if FakeLLM.tool_result_count(body) >= 2
        FakeLLM.text("both handled")
      else
        FakeLLM.tool_call([ [ "echo", { text: "hi" }, "call_mix_echo" ],
                            [ "charge_card", { amount_cents: 100 }, "call_mix_charge" ] ])
      end
    end
    definition = TestDefinition.new(tools: { "echo" => Echo, "charge_card" => ChargeCard })
    session, turn = start_session(definition)

    assert_equal :parked, Xeno::TurnRunner.new(turn, definition: definition).run
    assert_equal 1, Echo.executions, "ungated tool in the batch executes before the park"
    assert_equal 0, ChargeCard.executions

    charge_action = turn.actions.find_by(tool_name: "charge_card")
    Xeno::Inputs.approve!(charge_action)
    assert_equal :completed, Xeno::TurnRunner.new(turn.reload, definition: definition).run

    assert_equal 1, Echo.executions, "recorded echo must not re-run on resume"
    assert_equal 1, ChargeCard.executions
    assert_equal "both handled", session.chat.messages_association.order(:id).last.content
  end

  test "resume waits until every blocking action is resolved" do
    start_fake_llm do |body|
      if FakeLLM.tool_result_count(body) >= 2
        FakeLLM.text("done")
      else
        FakeLLM.tool_call([ [ "charge_card", { amount_cents: 1 }, "call_two_a" ],
                            [ "charge_card", { amount_cents: 2 }, "call_two_b" ] ])
      end
    end
    definition = TestDefinition.new(tools: { "charge_card" => ChargeCard })
    _session, turn = start_session(definition)
    Xeno::TurnRunner.new(turn, definition: definition).run

    first, second = turn.actions.order(:id).to_a

    assert_no_enqueued_jobs(only: Xeno::TurnJob) do
      Xeno::Inputs.approve!(first)
    end
    assert_equal "waiting", turn.reload.status, "one unresolved action keeps the turn parked"

    assert_enqueued_jobs(1, only: Xeno::TurnJob) do
      Xeno::Inputs.approve!(second)
    end
    assert_equal "pending", turn.reload.status
  end

  test "resolving a non-waiting action raises" do
    start_fake_llm(&charge_script)
    definition = TestDefinition.new(tools: { "charge_card" => ChargeCard })
    _session, turn = start_session(definition)
    Xeno::TurnRunner.new(turn, definition: definition).run

    action = turn.actions.sole
    Xeno::Inputs.approve!(action)
    assert_raises(Xeno::Error) { Xeno::Inputs.approve!(action.reload) }
  end
end
