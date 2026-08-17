# frozen_string_literal: true

require "test_helper"

# Regression: assume_model_exists and protocol are runtime attributes,
# not columns, so a session's second message — staged through a freshly
# loaded chat record — used to resolve the model strictly and raise
# ModelNotFoundError for any custom model. First messages worked because
# open! set the attributes on the in-memory record.
class RuntimeOptionsReapplyTest < ActiveSupport::TestCase
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
