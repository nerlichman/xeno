# frozen_string_literal: true

require "test_helper"

# The park/kill/rehydrate/inject/resume flow, run through RubyLLM's Rails
# acts_as persistence on xeno-owned tables.
#
# Process death is modeled as dropping every in-memory object and
# reloading fresh ActiveRecord instances — the DB rows are the only
# state, which is what a fresh worker process would see. A real kill -9
# through the full runtime is covered by the end-to-end scripts.
class TranscriptPersistenceTest < ActiveSupport::TestCase
  class ChargeCard < RubyLLM::Tool
    description "Charge the customer's card on file. Irreversible."
    parameter :amount_cents, type: :integer, description: "Amount in cents"

    def execute(amount_cents:)
      raise "PARKING VIOLATION: charge_card executed (amount=#{amount_cents})"
    end
  end

  def charge_card_script
    ->(body) do
      if FakeLLM.tool_result?(body)
        FakeLLM.text("Done — charged $42.00 (ch_42).")
      else
        FakeLLM.tool_call("charge_card", { amount_cents: 4200 }, id: "call_charge_001")
      end
    end
  end

  def build_chat_record
    chat = Xeno::Chat.new
    chat.assume_model_exists = true
    chat.model = "fake-model"
    chat.provider = "ollama"
    chat.save!
    chat
  end

  test "park -> object death -> rehydrate from rows -> inject -> resume" do
    fake = start_fake_llm(&charge_card_script)

    # --- phase 1: park (this "process" ends after generate) ---
    chat = build_chat_record
    chat.with_tools(ChargeCard)
    chat.ask_later("Charge $42 for the Pro plan.")
    response = chat.generate

    refute chat.complete?
    call = response.tool_calls.values.first
    assert_equal "charge_card", call.name
    assert_equal "call_charge_001", call.id

    # Persistence checks: user message + assistant message + tool_calls row.
    chat_id = chat.id
    assert_equal 2, Xeno::Message.where(chat_id: chat_id).count
    assistant_row = Xeno::Message.where(chat_id: chat_id, role: "assistant").sole
    tool_call_row = RubyLLM::ActiveRecord::ToolCall.where(message: assistant_row).sole
    assert_equal "call_charge_001", tool_call_row.tool_call_id
    assert_equal({ "amount_cents" => 4200 }, tool_call_row.arguments)

    # --- process death: drop every in-memory object ---
    chat = nil
    response = nil

    # --- phase 2: fresh "process" rehydrates purely from rows ---
    revived = Xeno::Chat.find(chat_id)
    revived.assume_model_exists = true
    revived.with_tools(ChargeCard)

    refute revived.complete?, "rehydrated chat must still owe a tool result"
    pending = revived.to_llm.messages.last.tool_calls
    revived_call = pending.values.first
    assert_equal "charge_card", revived_call.name
    assert_equal "call_charge_001", revived_call.id
    assert_equal({ "amount_cents" => 4200 }, revived_call.arguments)

    # --- the human approved; runtime performed the charge, injects the result ---
    result_row = revived.add_message(
      role: :tool,
      content: JSON.generate({ status: "succeeded", charge_id: "ch_42" }),
      tool_call_id: "call_charge_001"
    )
    assert_equal result_row, tool_call_row.reload.result,
      "tool result row must link back to the tool call it answers"

    final = revived.generate
    assert revived.complete?
    assert_match(/ch_42/, final.content)

    final_row = Xeno::Message.where(chat_id: chat_id, role: "assistant").order(:id).last
    assert_equal final.content, final_row.content
    # Token accounting lives in the per-attempt ledger now, linked to the
    # message it produced (message rows carry no token columns).
    assert_equal 42, final_row.tokens.input
    assert_equal 17, final_row.tokens.output

    # The resume request carried the full history with the linked result.
    resume_request = fake.requests.last
    roles = resume_request["messages"].map { |m| m["role"] }
    assert_equal %w[user assistant tool], roles
    assert_equal "call_charge_001", resume_request["messages"].last["tool_call_id"]

    # The gated tool's execute raises unconditionally — reaching here proves
    # neither we nor RubyLLM ever ran it.
  end

  test "hazard: killed mid-generate leaves a blank assistant row that flips complete?" do
    start_fake_llm(&charge_card_script)

    chat = build_chat_record
    chat.ask_later("Charge $42.")

    # Simulate the crash window: before_message has created the blank
    # assistant row, then the process dies before persist_message_completion.
    blank = chat.messages_association.create!(role: :assistant, content: "")

    revived = Xeno::Chat.find(chat.id)
    revived.assume_model_exists = true

    # The blank row makes the transcript look finished — resume logic MUST
    # clean trailing blank assistant rows before deciding anything.
    assert revived.complete?,
      "documents the hazard: blank assistant row reads as a completed turn"

    blank.destroy
    revived2 = Xeno::Chat.find(chat.id)
    revived2.assume_model_exists = true
    refute revived2.complete?, "after cleanup the turn is correctly unfinished"
  end

  test "add_message round-trips the thinking signature through the columns" do
    start_fake_llm

    chat = build_chat_record
    thinking = RubyLLM::Thinking.build(text: "let me think", signature: "sig_abc123")
    assert thinking, "Thinking.build should produce an object here"

    row = chat.add_message(RubyLLM::Message.new(role: :assistant, content: "hm", thinking: thinking))
    assert_equal "sig_abc123", row.reload.thinking_signature
    assert_equal "let me think", row.thinking_text

    revived = Xeno::Chat.find(chat.id).to_llm.messages.last
    assert_equal "sig_abc123", revived.thinking.signature
    assert_equal "let me think", revived.thinking.text
  end
end
