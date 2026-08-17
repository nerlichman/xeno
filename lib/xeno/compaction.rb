# frozen_string_literal: true

module Xeno
  # Summarize-and-replace compaction, run as a claimed turn (kind: "compaction") so it is exclusive,
  # queues behind active work, and replays safely after a crash.
  #
  # The system prompt and the last `compaction_tail_turns` turns survive verbatim; everything before
  # them is summarized by a throwaway model call and replaced in place.
  module Compaction # :nodoc:
    SUMMARY_PREFIX = "[Conversation summary — earlier messages were compacted]".freeze

    COMPACTION_PROMPT = <<~PROMPT.freeze
      You are compacting an agent conversation to reclaim context space.
      Write a dense summary of the transcript below; it will REPLACE those
      messages permanently. Separate completed work and decisions from
      remaining or open work. Retain every constraint, preference, fact,
      identifier, amount, and reference a future turn could need. Output
      only the summary text.
    PROMPT

    private

    def run_compaction
      unless compaction_applied?
        rows = @chat.messages_association.order(:id).to_a
        plan = compaction_plan(rows)

        if plan[:compact].size < 2
          record_compaction_result(compacted_messages: 0)
        else
          summary = with_heartbeat { compaction_summary(plan[:compact]) }
          apply_compaction!(plan, summary)
        end
      end

      turn.fenced_update!(token, status: "completed", heartbeat_at: Time.current)
      session.emit("turn.completed", { turn_id: turn.id, sequence: turn.sequence })
      advance_session
    end

    def compaction_applied?
      (turn.user_message || {}).key?("result")
    end

    # Everything strictly before the tail is compactable. The tail starts at the Nth-from-last user
    # row — a cut at a user row never splits an assistant's tool calls from their results. With too
    # few turns there is nothing to do.
    def compaction_plan(rows)
      system_rows, convo = rows.partition { |row| row.role == "system" }
      user_positions = convo.each_index.select { |i| convo[i].role == "user" }
      tail_turns = [ Xeno.config.compaction_tail_turns.to_i, 1 ].max

      if user_positions.size <= tail_turns
        { system: system_rows, compact: [], tail: convo }
      else
        tail_start = user_positions[-tail_turns]
        { system: system_rows, compact: convo[0...tail_start], tail: convo[tail_start..] }
      end
    end

    # One model call on a throwaway chat: no persistence, no tools. An earlier compaction's summary
    # is an ordinary early row here.
    def compaction_summary(rows)
      options = definition.config.model_options
      llm = RubyLLM.chat(
        model: definition.config.resolved_model,
        provider: options[:provider],
        protocol: options[:protocol],
        assume_model_exists: options.fetch(:assume_model_exists, false)
      )
      llm.with_instructions(COMPACTION_PROMPT)
      response = llm.ask(render_compaction_transcript(rows))
      response.content.to_s
    end

    def render_compaction_transcript(rows)
      rows.map { |row|
        parts = [ "#{row.role}:" ]
        parts << row.content if row.content.present?
        if row.respond_to?(:ruby_llm_tool_calls) && row.tool_call?
          row.ruby_llm_tool_calls.each { |call| parts << "[called #{call.name}(#{call.arguments.to_json})]" }
        end
        parts.join(" ")
      }.join("\n\n")
    end

    # The earliest compacted row becomes the summary in place; the rest are destroyed newest-first.
    # Rows, marker, and event commit together, so replay after a crash is a no-op past this
    # transaction.
    def apply_compaction!(plan, summary)
      keeper, *rest = plan[:compact]

      ActiveRecord::Base.transaction do
        rest.reverse_each(&:destroy!)
        # A parent tool call on a surviving earlier row would otherwise dangle a result FK at the
        # repurposed keeper.
        keeper.ruby_llm_tool_calls.destroy_all
        keeper.ruby_llm_parent_tool_call&.update!(result: nil)
        keeper.update!(
          role: "user",
          content: "#{SUMMARY_PREFIX}\n\n#{summary}",
          thinking_text: nil, thinking_signature: nil
        )
        record_compaction_result(compacted_messages: plan[:compact].size)
      end
      sync_llm_messages
    end

    def record_compaction_result(compacted_messages:)
      ActiveRecord::Base.transaction do
        turn.fenced_update!(token,
          user_message: (turn.user_message || {}).merge("result" => { "compacted_messages" => compacted_messages }))
        session.emit("compaction.completed", { turn_id: turn.id, compacted_messages: compacted_messages })
      end
    end

    # After a message turn completes, stage a compaction turn when the last model call crossed the
    # threshold share of the model's window (config fallback when the registry doesn't know it).
    def maybe_stage_compaction
      threshold = Xeno.config.compaction_threshold
      return unless threshold
      return if turn.kind == "compaction"

      limit = compaction_context_limit
      return unless limit

      used = compaction_tokens_used
      return unless used && used >= (limit * threshold.to_f)
      return if session.turns.where(kind: "compaction", status: %w[pending running]).exists?

      session.stage_compaction_turn!(reason: "auto", used: used, limit: limit)
    end

    def compaction_context_limit
      window = begin
        @chat.to_llm.model&.context_window
      rescue StandardError
        nil
      end
      window || Xeno.config.compaction_context_window
    end

    # The provider's count for the last completed call, read from the per-attempt usage ledger.
    def compaction_tokens_used
      last = @chat.ruby_llm_usages.where(operation: "chat", status: "succeeded")
                  .where.not(input_tokens: nil).order(:created_at, :id).last
      return nil unless last

      last.input_tokens.to_i + last.output_tokens.to_i
    end
  end
end
