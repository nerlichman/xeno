# frozen_string_literal: true

module Xeno
  # The one framework tool in v0.1. It has no executable body: the model
  # calling it parks the turn with an input.requested event, and a human's
  # answer is injected as the tool result on resume — the same mechanics as
  # approvals. Registered on every chat (outside the Xeno::Tools namespace,
  # which belongs to the app's agent/tools/).
  class AskQuestion < Tool
    description "Ask the human a question and wait for their answer. " \
                "Use when you need information or a decision only they can provide."
    parameter :question, description: "The question to ask"
    parameter :choices, type: :array, required: false,
                        description: "Optional list of suggested answers"

    def execute(question:, choices: nil)
      raise "ask_question is never executed — the runtime parks the turn instead"
    end
  end
end
