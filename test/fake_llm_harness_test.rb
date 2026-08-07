require "test_helper"

# Proves the deterministic test harness: RubyLLM's decomposed v2 loop
# (ask_later → generate → add_message → generate) running against the
# in-process FakeLLM server, no network, no keys.
class FakeLLMHarnessTest < ActiveSupport::TestCase
  class Noop < RubyLLM::Tool
    description "Does nothing."
    parameter :x, type: :integer, description: "Anything"

    def execute(x:)
      raise "harness tools are never executed by the runtime (x=#{x})"
    end
  end

  test "default script returns a text answer" do
    start_fake_llm
    chat = fake_chat
    chat.ask_later("hi")
    response = chat.generate

    assert_equal "ok", response.content
    assert chat.complete?
  end

  test "scripted tool call drives the decomposed loop without executing tools" do
    fake = start_fake_llm do |body|
      if FakeLLM.tool_result?(body)
        FakeLLM.text("done")
      else
        FakeLLM.tool_call("noop", { x: 1 }, id: "call_noop_1")
      end
    end

    chat = fake_chat.with_tools(Noop)
    chat.ask_later("call the tool")
    response = chat.generate

    refute chat.complete?
    call = response.tool_calls.values.first
    assert_equal "noop", call.name
    assert_equal "call_noop_1", call.id

    chat.add_message(role: :tool, content: "result-injected", tool_call_id: call.id)
    final = chat.generate

    assert_equal "done", final.content
    assert chat.complete?

    resume_request = fake.requests.last
    assert_equal %w[user assistant tool], resume_request["messages"].map { |m| m["role"] }
    assert_equal "call_noop_1", resume_request["messages"].last["tool_call_id"]
  end
end
