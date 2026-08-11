# frozen_string_literal: true

require "test_helper"
require "xeno/info"

# Stretch 3: the hooks/ slot — observe-only handlers firing after each
# event commits, at-least-once. Raising handlers are logged and skipped;
# hooks can never break the runtime.
class HooksTest < ActiveSupport::TestCase
  HOOK_RB = <<~RUBY
    Xeno.hook "turn.completed" do |event|
      # observe
    end

    Xeno.hook "*" do |event|
      # observe everything
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

  def with_definition(definition)
    Xeno.instance_variable_set(:@definition, definition)
    yield
  ensure
    Xeno.reset_definition!
  end

  # --- discovery -----------------------------------------------------------

  test "hooks/*.rb are discovered; typed and wildcard handlers register" do
    with_agent_dir({ "instructions.md" => "hi", "hooks/metrics.rb" => HOOK_RB }) do |root|
      definition = load_definition(root)

      assert_empty definition.diagnostics.map(&:message)
      assert_equal 1, definition.hooks["turn.completed"].size
      assert_equal 1, definition.hooks["*"].size

      output = Xeno::Info.render(definition)
      assert_includes output, "Hooks (observe-only, at-least-once):"
      assert_includes output, "turn.completed"
    end
  end

  test "diagnostics: unknown event type warns, DSL-less file warns, broken file errors" do
    with_agent_dir({ "instructions.md" => "hi",
                     "hooks/typo.rb" => 'Xeno.hook("turn.compelted") { |e| }' }) do |root|
      definition = load_definition(root)
      assert definition.diagnostics.any? { |d| d.message.include?("not in the event vocabulary") }
    end

    with_agent_dir({ "instructions.md" => "hi", "hooks/empty.rb" => "# nothing\n" }) do |root|
      definition = load_definition(root)
      assert definition.diagnostics.any? { |d| d.message.include?("never called Xeno.hook") }
    end

    with_agent_dir({ "instructions.md" => "hi", "hooks/broken.rb" => "raise 'boom'" }) do |root|
      definition = load_definition(root)
      assert definition.errors?
      assert definition.diagnostics.any? { |d| d.message.include?("hooks/broken.rb: failed to load") }
    end
  end

  # --- firing --------------------------------------------------------------

  test "hooks observe a full turn's events in order, typed before wildcard" do
    start_fake_llm
    seen = []
    definition = TestDefinition.new(hooks: {
      "turn.completed" => [ ->(event) { seen << [ :typed, event.event_type, event.index ] } ],
      "*" => [ ->(event) { seen << [ :wildcard, event.event_type, event.index ] } ]
    })

    with_definition(definition) do
      session = Xeno::Session.open!(message: "hi", definition: definition)
      Xeno::TurnRunner.new(session.turns.sole, definition: definition).run

      wildcard_types = seen.select { |kind, _, _| kind == :wildcard }.map { |_, type, _| type }
      assert_equal session.events.order(:index).pluck(:event_type), wildcard_types,
        "the wildcard hook saw every committed event, in order"

      typed = seen.select { |kind, _, _| kind == :typed }
      assert_equal [ "turn.completed" ], typed.map { |_, type, _| type }
      completed_index = seen.index { |kind, type, _| kind == :typed && type == "turn.completed" }
      wildcard_completed = seen.index { |kind, type, _| kind == :wildcard && type == "turn.completed" }
      assert_operator completed_index, :<, wildcard_completed, "typed handlers fire before the wildcard"
    end
  end

  test "a raising hook is logged and skipped; the turn and the other handlers are untouched" do
    start_fake_llm
    survived = []
    definition = TestDefinition.new(hooks: {
      "*" => [
        ->(_event) { raise "observer bug" },
        ->(event) { survived << event.event_type }
      ]
    })

    with_definition(definition) do
      session = Xeno::Session.open!(message: "hi", definition: definition)
      assert_equal :completed, Xeno::TurnRunner.new(session.turns.sole, definition: definition).run

      assert_equal "completed", session.turns.sole.reload.status, "hooks can never break the runtime"
      assert_includes survived, "turn.completed", "later handlers still ran"
    end
  end
end
