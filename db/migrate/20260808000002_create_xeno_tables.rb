class CreateXenoTables < ActiveRecord::Migration[8.1]
  def change
    create_table :xeno_chats do |t|
      t.boolean :cancelled, null: false, default: false
      t.references :ruby_llm_model, foreign_key: { to_table: :ruby_llm_models }
      t.timestamps
    end

    create_table :xeno_messages do |t|
      t.string :role, null: false
      t.text :content
      t.boolean :cache_until_here, null: false, default: false
      t.text :thinking_text
      t.text :thinking_signature
      t.json :citations
      t.string :finish_reason
      t.references :chat, null: false, foreign_key: { to_table: :xeno_chats }
      t.timestamps

      t.index :role
    end

    create_table :xeno_sessions do |t|
      t.string :agent, null: false
      t.string :status, null: false, default: "running"
      t.string :channel
      t.string :continuation_token
      t.string :title
      t.json :principal
      t.json :metadata, default: {}
      t.json :state, null: false, default: {}
      t.references :chat, null: false, foreign_key: { to_table: :xeno_chats }
      t.timestamps

      t.index :continuation_token, unique: true
      t.index :status
    end

    create_table :xeno_turns do |t|
      t.references :session, null: false, foreign_key: { to_table: :xeno_sessions }
      t.integer :sequence, null: false
      t.string :status, null: false, default: "pending"
      t.string :kind, null: false, default: "message"
      t.integer :claim_token, null: false, default: 0
      t.datetime :heartbeat_at
      t.integer :attempts, null: false, default: 0
      t.integer :resumes, null: false, default: 0
      t.integer :steps_count, null: false, default: 0
      t.boolean :transcript_deferred, null: false, default: false
      t.json :user_message
      t.json :error
      t.timestamps

      t.index [ :session_id, :sequence ], unique: true
      t.index :status
    end

    create_table :xeno_actions do |t|
      t.references :turn, null: false, foreign_key: { to_table: :xeno_turns }
      t.string :tool_call_id, null: false
      t.string :tool_name, null: false
      t.string :kind, null: false, default: "tool"
      t.string :status, null: false, default: "pending"
      t.json :input
      t.json :output
      t.datetime :resolved_at
      t.json :resolved_by
      t.timestamps

      t.index [ :turn_id, :tool_call_id ], unique: true
    end

    create_table :xeno_events do |t|
      t.references :session, null: false, foreign_key: { to_table: :xeno_sessions }
      t.integer :index, null: false
      t.string :event_type, null: false
      t.json :data
      t.datetime :created_at, null: false

      t.index [ :session_id, :index ], unique: true
    end

    create_table :xeno_pending_messages do |t|
      t.references :session, null: false, foreign_key: { to_table: :xeno_sessions }
      t.json :payload, null: false
      t.timestamps
    end

    create_table :xeno_dedups do |t|
      t.string :scope, null: false
      t.string :key, null: false
      t.json :metadata
      t.datetime :created_at, null: false

      t.index [ :scope, :key ], unique: true
    end
  end
end
