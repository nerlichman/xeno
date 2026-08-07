# The transcript layer: xeno-owned copies of RubyLLM's acts_as tables
# (chats, messages, tool_calls, models). Column set mirrors RubyLLM's
# install generator templates so the acts_as persistence paths keep
# every column they know how to write (thinking, tokens, costs).
class CreateXenoLlmTables < ActiveRecord::Migration[8.1]
  def change
    create_table :xeno_models do |t|
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

    create_table :xeno_chats do |t|
      t.boolean :cancelled, null: false, default: false
      t.references :model, foreign_key: { to_table: :xeno_models }
      t.timestamps
    end

    create_table :xeno_messages do |t|
      t.string :role, null: false
      t.text :content
      t.boolean :cache_until_here, null: false, default: false
      t.text :thinking_text
      t.text :thinking_signature
      t.integer :thinking_tokens
      t.json :citations
      t.integer :input_tokens
      t.integer :output_tokens
      t.integer :cache_read_tokens
      t.integer :cache_write_tokens
      t.decimal :total_cost, precision: 16, scale: 10
      t.json :cost_details
      t.string :finish_reason
      t.references :chat, null: false, foreign_key: { to_table: :xeno_chats }
      t.references :model, foreign_key: { to_table: :xeno_models }
      t.timestamps

      t.index :role
    end

    create_table :xeno_tool_calls do |t|
      t.string :tool_call_id, null: false
      t.string :name, null: false
      t.text :thought_signature
      t.json :arguments, default: {}
      t.references :message, null: false, foreign_key: { to_table: :xeno_messages }
      t.timestamps

      t.index :tool_call_id, unique: true
      t.index :name
    end

    # Tool-result messages point back at the tool call they answer.
    add_reference :xeno_messages, :tool_call, foreign_key: { to_table: :xeno_tool_calls }
  end
end
