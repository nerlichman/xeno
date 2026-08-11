# frozen_string_literal: true

require "test_helper"
require "xeno/info"

# agent/instructions.rb — dynamic instructions resolved at turn-stage
# time with the session context (the current_user use case), composed with
# the static instructions.md (static first, dynamic appended).
class DynamicInstructionsTest < ActiveSupport::TestCase
  DYNAMIC_RB = <<~RUBY
    Xeno.instructions do |context|
      "You are helping \#{context.principal&.dig("name") || "a guest"}."
    end
  RUBY

  def load_definition(root)
    Xeno::AgentDefinition.load(root, name: "test")
  end

  def with_agent_dir(files)
    Dir.mktmpdir do |dir|
      root = Pathname(dir)
      files.each do |path, content|
        full = root.join(path)
        full.dirname.mkpath
        full.write(content)
      end
      yield root
    end
  end

  # --- discovery + composition -------------------------------------------

  test "instructions.rb is discovered and composes after the static markdown" do
    with_agent_dir({ "instructions.md" => "Be helpful.", "instructions.rb" => DYNAMIC_RB }) do |root|
      definition = load_definition(root)

      assert definition.dynamic_instructions?
      assert_empty definition.diagnostics.map(&:message)

      session = Struct.new(:principal).new({ "name" => "Ada" })
      assert_equal "Be helpful.\n\nYou are helping Ada.", definition.instructions_for(session: session)
    end
  end

  test "instructions.rb alone is a valid system prompt (no missing-instructions error)" do
    with_agent_dir({ "instructions.rb" => DYNAMIC_RB }) do |root|
      definition = load_definition(root)

      refute definition.errors?, definition.diagnostics.map(&:message).join("; ")
      session = Struct.new(:principal).new(nil)
      assert_equal "You are helping a guest.", definition.instructions_for(session: session)
    end
  end

  test "broken instructions.rb is a diagnostic, not a crash; forgetting the DSL is a warning" do
    with_agent_dir({ "instructions.md" => "hi", "instructions.rb" => "raise 'boom at load'" }) do |root|
      definition = load_definition(root)
      assert definition.errors?
      assert definition.diagnostics.any? { |d| d.message.include?("instructions.rb failed to load") }
    end

    with_agent_dir({ "instructions.md" => "hi", "instructions.rb" => "# forgot the DSL\n" }) do |root|
      definition = load_definition(root)
      refute definition.errors?
      assert definition.diagnostics.any? { |d| d.message.include?("never called Xeno.instructions") }
      refute definition.dynamic_instructions?
    end
  end

  test "instructions.rb at the agent root is never flagged as misplaced" do
    with_agent_dir({ "instructions.md" => "hi", "instructions.rb" => DYNAMIC_RB }) do |root|
      definition = load_definition(root)
      refute definition.diagnostics.any? { |d| d.message.include?("ruby files at the agent root") }
    end
  end

  test "a block that raises at resolve time falls back to the static instructions" do
    with_agent_dir({ "instructions.md" => "Static survives.",
                     "instructions.rb" => "Xeno.instructions { |_ctx| raise 'boom at resolve' }" }) do |root|
      definition = load_definition(root)
      assert definition.dynamic_instructions?

      session = Struct.new(:principal).new({ "name" => "Ada" })
      assert_equal "Static survives.", definition.instructions_for(session: session)
    end
  end

  test "xeno:info marks dynamic instructions" do
    with_agent_dir({ "instructions.md" => "Be helpful.", "instructions.rb" => DYNAMIC_RB }) do |root|
      output = Xeno::Info.render(load_definition(root))
      assert_includes output, "instructions.md"
      assert_includes output, "dynamic (instructions.rb, resolved per turn)"
    end

    with_agent_dir({ "instructions.rb" => DYNAMIC_RB }) do |root|
      output = Xeno::Info.render(load_definition(root))
      assert_includes output, "dynamic only (instructions.rb, resolved per turn)"
    end
  end

  # --- runtime: per-principal system prompts ------------------------------

  test "two sessions with different principals get different instructions" do
    fake = start_fake_llm { |_body| FakeLLM.text("hello") }

    with_agent_dir({
      "agent.rb" => 'Xeno.agent { model "fake-model", provider: :ollama, assume_model_exists: true }',
      "instructions.md" => "Be helpful.",
      "instructions.rb" => DYNAMIC_RB
    }) do |root|
      definition = load_definition(root)

      ada = Xeno::Session.open!(message: "hi", principal: { "name" => "Ada" }, definition: definition)
      grace = Xeno::Session.open!(message: "hi", principal: { "name" => "Grace" }, definition: definition)
      Xeno::TurnRunner.new(ada.turns.sole, definition: definition).run
      Xeno::TurnRunner.new(grace.turns.sole, definition: definition).run

      systems = fake.requests.map { |r| r["messages"].find { |m| m["role"] == "system" }&.fetch("content") }
      assert_equal 2, systems.size
      assert systems.any? { |s| s.include?("You are helping Ada.") }, "Ada's session carries her principal"
      assert systems.any? { |s| s.include?("You are helping Grace.") }, "Grace's session carries hers"
      assert systems.all? { |s| s.start_with?("Be helpful.") }, "static markdown leads in both"
    end
  end

  test "dynamic instructions re-resolve on every turn stage" do
    fake = start_fake_llm { |_body| FakeLLM.text("ok") }
    calls = 0
    definition = TestDefinition.new(
      instructions: "Static.",
      dynamic_instructions: ->(_ctx) { "Resolution ##{calls += 1}." }
    )

    session = Xeno::Session.open!(message: "one", definition: definition)
    Xeno::TurnRunner.new(session.turns.sole, definition: definition).run
    session.stage_turn!("two", definition: definition)
    Xeno::TurnRunner.new(session.turns.order(:sequence).last, definition: definition).run

    systems = fake.requests.map { |r| r["messages"].find { |m| m["role"] == "system" }&.fetch("content") }
    assert_includes systems.first, "Resolution #1."
    assert_includes systems.last, "Resolution #2.", "each turn stage resolves fresh"
  end
end
