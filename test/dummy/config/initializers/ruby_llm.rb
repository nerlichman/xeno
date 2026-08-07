# The demo/tests point the Ollama provider at the deterministic fake
# Chat-Completions server. Harmless when the variable is absent.
if ENV["FAKE_LLM_URL"]
  RubyLLM.configure { |c| c.ollama_api_base = ENV["FAKE_LLM_URL"] }
end
