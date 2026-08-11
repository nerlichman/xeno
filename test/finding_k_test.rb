# frozen_string_literal: true

require "test_helper"

# Regression, field-confirmed: assume_model_exists and protocol
# are runtime attributes, not columns. The SECOND message of a session
# stages through a freshly loaded chat record, and with_instructions
# triggers the first to_llm build — which resolved the model strictly
# (ModelNotFoundError for any custom/OpenAI-compatible model) and with the
# provider's default protocol. First messages worked (open! set the attrs
# on the in-memory record), which is exactly why this survived to the
# field run.
class FindingKTest < ActiveSupport::TestCase
  setup do
    @old_key = RubyLLM.config.openai_api_key
    @old_base = RubyLLM.config.openai_api_base
  end

  teardown do
    RubyLLM.configure do |c|
      c.openai_api_key = @old_key
      c.openai_api_base = @old_base
    end
  end

  test "the second message of a custom-model session stages without ModelNotFoundError" do
    fake = start_fake_llm
    RubyLLM.configure do |c|
      c.openai_api_key = "test-key"
      c.openai_api_base = fake.url
    end
    definition = TestDefinition.new(
      model: "never-registered-model",
      model_options: { provider: :openai, assume_model_exists: true, protocol: :chat_completions }
    )
    session = Xeno::Session.open!(message: "hi", definition: definition)
    assert_equal :completed, Xeno::TurnRunner.new(session.turns.sole, definition: definition).run

    # A fresh record is what every new request/process sees.
    fresh = Xeno::Session.find(session.id)
    turn = fresh.stage_turn!("again", definition: definition)

    assert_equal 2, turn.sequence
    assert_equal :completed, Xeno::TurnRunner.new(turn, definition: definition).run
  end
end
