# frozen_string_literal: true

require "test_helper"
require "xeno/info"

class AgentDefinitionTest < ActiveSupport::TestCase
  # --- happy path: the dummy app's real agent/ directory through Zeitwerk ---

  test "resolves the dummy app's agent directory" do
    definition = Xeno.definition

    assert_equal "dummy", definition.name
    assert_match(/dummy app's test agent/, definition.instructions)
    assert_equal "fake-model", definition.config.model
    assert_equal({ provider: :ollama, assume_model_exists: true }, definition.config.model_options)

    assert_equal %w[charge_card get_weather], definition.tools.keys
    assert_equal Xeno::Tools::GetWeather, definition.tools["get_weather"]
    assert_equal :always, Xeno::Tools::ChargeCard.approval
    assert_equal %w[weekly_recap], definition.schedules.keys
    assert_equal %w[slack], definition.channels.keys
    assert_empty definition.diagnostics.map(&:message)
  end

  test "tool names are path-derived, not namespace-derived" do
    assert_equal "get_weather", Xeno::Tools::GetWeather.tool_name
    assert_equal "get_weather", Xeno::Tools::GetWeather.new.name
  end

  test "xeno:info renders the resolved agent" do
    output = Xeno::Info.render

    assert_match(/Agent: dummy/, output)
    assert_match(/Model: fake-model/, output)
    assert_match(/get_weather\s+Xeno::Tools::GetWeather\s+— Return current weather/, output)
    refute_match(/Diagnostics:/, output)
  end

  # --- diagnostics: broken layouts in temp directories never raise ---

  def load_definition(root, resolver: nil)
    Xeno::AgentDefinition.load(root, name: "test", resolver: resolver)
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

  test "missing agent directory is an error diagnostic" do
    definition = load_definition("/nonexistent/agent")
    assert definition.errors?
    assert_match(/no agent\/ directory/, definition.diagnostics.first.message)
  end

  test "missing instructions (no .md and no .rb) is an error" do
    with_agent_dir({}) do |root|
      definition = load_definition(root)
      assert definition.errors?
      assert definition.diagnostics.any? { |d| d.message.include?("instructions are missing") }
    end
  end

  test "broken agent.rb is reported, not raised" do
    files = {
      "agent.rb" => "Xeno.agent do\n  raise 'boom'\nend\n",
      "instructions.md" => "hi"
    }
    with_agent_dir(files) do |root|
      definition = load_definition(root)
      assert definition.diagnostics.any? { |d| d.error? && d.message.include?("agent.rb failed to load") }
    end
  end

  test "agent.rb that never calls Xeno.agent gets a warning and defaults" do
    files = { "agent.rb" => "# forgot the DSL\n", "instructions.md" => "hi" }
    with_agent_dir(files) do |root|
      definition = load_definition(root)
      assert definition.diagnostics.any? { |d| d.message.include?("never called Xeno.agent") }
      assert_nil definition.config.model
    end
  end

  test "bad tool slugs and non-tool constants are errors; good tools still load" do
    files = {
      "instructions.md" => "hi",
      "tools/Get-Weather.rb" => "",
      "tools/lookup.rb" => "",
      "tools/broken.rb" => ""
    }
    resolver = lambda do |slug|
      case slug
      when "lookup" then Xeno::Tools::GetWeather
      when "broken" then String
      end
    end
    with_agent_dir(files) do |root|
      definition = load_definition(root, resolver: resolver)

      messages = definition.diagnostics.map(&:message)
      assert messages.any? { |m| m.include?('invalid tool name "Get-Weather"') }
      assert messages.any? { |m| m.include?("broken.rb") && m.include?("must subclass Xeno::Tool") }
      assert_equal %w[lookup], definition.tools.keys
    end
  end

  test "a plain RubyLLM::Tool subclass is rejected with a diagnostic (approval gate depends on Xeno::Tool)" do
    plain = Class.new(RubyLLM::Tool)
    with_agent_dir({ "instructions.md" => "hi", "tools/plain.rb" => "" }) do |root|
      definition = load_definition(root, resolver: ->(_slug) { plain })
      messages = definition.diagnostics.map(&:message)
      assert messages.any? { |m| m.include?("plain.rb") && m.include?("must subclass Xeno::Tool") }
      assert_empty definition.tools
    end
  end

  test "tool_name keeps the _tool suffix so the slug-keyed lookup (and the approval gate) matches" do
    charge_card_tool = Class.new(Xeno::Tool)
    Xeno::Tools.const_set(:ChargeCardTool, charge_card_tool)
    begin
      assert_equal "charge_card_tool", charge_card_tool.tool_name
      assert_equal "charge_card_tool", charge_card_tool.new.name
    ensure
      Xeno::Tools.send(:remove_const, :ChargeCardTool)
    end
  end

  test "misplaced ruby files and unknown directories get warnings" do
    files = {
      "instructions.md" => "hi",
      "my_tool.rb" => "",
      "prompts/one.md" => ""
    }
    with_agent_dir(files) do |root|
      definition = load_definition(root)
      messages = definition.diagnostics.map(&:message)
      assert messages.any? { |m| m.include?("my_tool.rb") && m.include?("tools/") }
      assert messages.any? { |m| m.include?("prompts/: not a known slot") }
    end
  end
end
