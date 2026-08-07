# A hand-built agent definition for runtime tests: fake-model over the
# FakeLLM server, tools injected per test.
class TestDefinition
  attr_reader :config, :tools, :instructions, :name, :diagnostics

  def initialize(tools: {}, instructions: "You are a test agent.", model: "fake-model",
                 model_options: { provider: :ollama, assume_model_exists: true },
                 dynamic_instructions: nil, hooks: {})
    @config = Xeno::AgentConfig.new
    @config.model(model, **model_options)
    @tools = tools
    @instructions = instructions
    @dynamic_instructions = dynamic_instructions
    @hooks = hooks
    @name = "test"
    @diagnostics = []
  end

  attr_reader :hooks

  def tool_classes = tools.values
  def errors? = false
  def dynamic_instructions? = !@dynamic_instructions.nil?

  def instructions_for(session: nil)
    parts = [ @instructions ]
    if @dynamic_instructions
      context = Xeno::AgentDefinition::InstructionContext.new(session: session, principal: session&.principal)
      parts << @dynamic_instructions.call(context).to_s
    end
    parts.compact.map(&:strip).reject(&:empty?).join("\n\n").presence
  end
end
