# frozen_string_literal: true

module Xeno
  # The built-in question tool. It has no executable body: the model calling it parks the turn, and
  # a human's answer is injected as the tool result on resume — the same mechanics as approvals.
  # Registered on every chat, outside the Xeno::Tools namespace that belongs to the app.
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
