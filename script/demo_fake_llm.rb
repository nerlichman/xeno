# frozen_string_literal: true

# The demo's stand-in model: asks for charge_card once, then answers with
# the receipt. Run by script/demo.sh; port via FAKE_LLM_PORT.
require_relative "../test/support/fake_llm"

fake = FakeLLM.new(port: Integer(ENV.fetch("FAKE_LLM_PORT", "4666"))) do |body|
  if FakeLLM.tool_result?(body)
    result = JSON.parse(body["messages"].find { |m| m["role"] == "tool" }["content"])
    FakeLLM.text("Done! I charged $42.00 — receipt #{result['charge_id']}.")
  else
    FakeLLM.tool_call("charge_card", { amount_cents: 4200 }, id: "call_demo_live")
  end
end

fake.start
puts "fake LLM listening on #{fake.url}"
sleep
