module Xeno
  # The persisted RubyLLM chat backing one session's transcript.
  # Owned by xeno — host apps with their own acts_as chat classes are
  # unaffected; the message class below pins the transcript inside the
  # engine namespace. Models, tool calls, usage, and batches are RubyLLM
  # library records (ruby_llm_* tables), polymorphic toward this class.
  class Chat < ApplicationRecord
    acts_as_chat message_class: "Xeno::Message"

    # assume_model_exists and protocol are runtime attributes, not columns —
    # a freshly loaded record loses them, and the first to_llm build (which
    # with_instructions triggers) then resolves the model strictly and with
    # the provider's default protocol: ModelNotFoundError on the SECOND
    # message of any session using a custom/OpenAI-compatible model
    # (finding K). Every entry point re-applies them from the definition.
    def apply_runtime_options!(model_options)
      self.assume_model_exists = model_options[:assume_model_exists] if model_options.key?(:assume_model_exists)
      self.protocol = model_options[:protocol] if model_options.key?(:protocol)
      self
    end
  end
end
