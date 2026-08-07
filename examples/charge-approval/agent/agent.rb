RubyLLM.configure do |c|
  c.openai_api_base = "https://integrate.api.nvidia.com/v1"
  c.openai_api_key  = ENV["NVIDIA_API_KEY"]
end

Xeno.agent do
  model "meta/llama-3.3-70b-instruct",
        provider: :openai, protocol: :chat_completions, assume_model_exists: true
end

