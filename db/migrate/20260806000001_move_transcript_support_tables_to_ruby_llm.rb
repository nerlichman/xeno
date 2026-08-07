# ruby_llm 2aaddf96: models, tool calls, usage, and batches become library
# records on RubyLLM-owned ruby_llm_* tables (polymorphic toward the app's
# chat/message classes); message rows stop carrying token/cost accounting
# (the per-attempt ruby_llm_usage_entries ledger replaces it). Table shapes
# mirror upstream's install templates.
#
# DESTRUCTIVE (pre-release, no installs to migrate): xeno_tool_calls and
# xeno_models are dropped without moving their rows, and the accounting
# columns on xeno_messages are removed with their data. Existing chats keep
# their transcript text but lose tool-call linkage and usage history.
class MoveTranscriptSupportTablesToRubyLlm < ActiveRecord::Migration[8.1]
  def change
    create_table :ruby_llm_models do |t|
      t.string :model_id, null: false
      t.string :name, null: false
      t.string :provider, null: false
      t.string :family
      t.datetime :model_created_at
      t.integer :context_window
      t.integer :max_output_tokens
      t.date :knowledge_cutoff
      t.json :modalities, default: {}
      t.json :capabilities, default: []
      t.json :pricing, default: {}
      t.json :metadata, default: {}
      t.timestamps

      t.index [ :provider, :model_id ], unique: true
      t.index :provider
      t.index :family
    end

    create_table :ruby_llm_tool_calls do |t|
      t.references :message, polymorphic: true, null: false, index: false
      t.references :result, polymorphic: true, index: false
      t.string :tool_call_id, null: false
      t.string :name, null: false
      t.text :thought_signature
      t.json :arguments, default: {}
      t.timestamps

      t.index [ :message_type, :message_id ]
      t.index [ :result_type, :result_id ]
      t.index :tool_call_id, unique: true
      t.index :name
    end

    create_table :ruby_llm_usage_entries do |t|
      t.references :chat, polymorphic: true, null: false, index: false
      t.references :message, polymorphic: true, index: false
      t.string :operation, null: false
      t.string :provider, null: false
      t.string :model, null: false
      t.string :status, null: false
      t.integer :input_tokens
      t.integer :output_tokens
      t.integer :cache_read_tokens
      t.integer :cache_write_tokens
      t.integer :thinking_tokens
      t.decimal :input_cost, precision: 16, scale: 10
      t.decimal :output_cost, precision: 16, scale: 10
      t.decimal :cache_read_cost, precision: 16, scale: 10
      t.decimal :cache_write_cost, precision: 16, scale: 10
      t.decimal :thinking_cost, precision: 16, scale: 10
      t.decimal :total_cost, precision: 16, scale: 10
      t.timestamps

      t.index [ :chat_type, :chat_id ]
      t.index [ :message_type, :message_id ]
      t.index :status
      t.check_constraint "operation IN ('chat', 'embedding', 'moderation', 'image', 'speech', 'transcription')"
      t.check_constraint "status IN ('pending', 'succeeded', 'failed', 'cancelled')"
    end

    create_table :ruby_llm_batches do |t|
      t.string :provider_batch_id, null: false
      t.string :provider, null: false
      t.string :status
      t.boolean :completed, null: false, default: false
      t.string :chat_type
      t.string :batch_protocol
      t.json :chat_ids, default: []
      t.json :request_counts
      t.timestamps

      t.index [ :provider, :provider_batch_id ], unique: true
      t.index :status
    end

    # acts_as_chat hard-wires belongs_to :model with this foreign key.
    # Upstream's fresh-install template makes it null: false; here it stays
    # nullable because pre-existing xeno_chats rows have nothing to point at
    # (the association is optional and resolve_model fills it on save).
    add_reference :xeno_chats, :ruby_llm_model, foreign_key: { to_table: :ruby_llm_models }

    remove_reference :xeno_messages, :tool_call, foreign_key: { to_table: :xeno_tool_calls }
    remove_reference :xeno_messages, :model, foreign_key: { to_table: :xeno_models }
    remove_reference :xeno_chats, :model, foreign_key: { to_table: :xeno_models }

    remove_column :xeno_messages, :thinking_tokens, :integer
    remove_column :xeno_messages, :input_tokens, :integer
    remove_column :xeno_messages, :output_tokens, :integer
    remove_column :xeno_messages, :cache_read_tokens, :integer
    remove_column :xeno_messages, :cache_write_tokens, :integer
    remove_column :xeno_messages, :total_cost, :decimal, precision: 16, scale: 10
    remove_column :xeno_messages, :cost_details, :json

    drop_table :xeno_tool_calls do |t|
      t.string :tool_call_id, null: false
      t.string :name, null: false
      t.text :thought_signature
      t.json :arguments, default: {}
      t.references :message, null: false
      t.timestamps
    end

    drop_table :xeno_models do |t|
      t.string :model_id, null: false
      t.string :name, null: false
      t.string :provider, null: false
      t.string :family
      t.datetime :model_created_at
      t.integer :context_window
      t.integer :max_output_tokens
      t.date :knowledge_cutoff
      t.json :modalities, default: {}
      t.json :capabilities, default: []
      t.json :pricing, default: {}
      t.json :metadata, default: {}
      t.timestamps
    end
  end
end
