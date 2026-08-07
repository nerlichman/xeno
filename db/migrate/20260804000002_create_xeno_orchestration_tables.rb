# The orchestration layer above the transcript: sessions, turns (claim/
# heartbeat/fencing), actions (tool-call checkpoint + approval state),
# events (the append-only session stream), pending messages (drained into
# the next turn). Per spike #2 there is no steps table — a step's output
# lives in xeno_messages/xeno_tool_calls.
class CreateXenoOrchestrationTables < ActiveRecord::Migration[8.1]
  def change
    create_table :xeno_sessions do |t|
      t.string :agent, null: false
      t.string :status, null: false, default: "running" # running|waiting|completed|failed
      t.string :channel
      t.string :continuation_token
      t.string :title
      t.json :principal
      t.json :metadata, default: {}
      t.references :chat, null: false, foreign_key: { to_table: :xeno_chats }
      t.timestamps

      t.index :continuation_token, unique: true
      t.index :status
    end

    create_table :xeno_turns do |t|
      t.references :session, null: false, foreign_key: { to_table: :xeno_sessions }
      t.integer :sequence, null: false
      t.string :status, null: false, default: "pending" # pending|running|waiting|completed|failed|cancelled
      t.integer :claim_token, null: false, default: 0
      t.datetime :heartbeat_at
      t.integer :attempts, null: false, default: 0
      t.integer :steps_count, null: false, default: 0
      t.json :user_message
      t.json :error
      t.timestamps

      t.index [ :session_id, :sequence ], unique: true
      t.index :status
    end

    create_table :xeno_actions do |t|
      t.references :turn, null: false, foreign_key: { to_table: :xeno_turns }
      t.string :tool_call_id, null: false # the provider call id (xeno_tool_calls.tool_call_id)
      t.string :tool_name, null: false
      t.string :kind, null: false, default: "tool" # tool|question
      t.string :status, null: false, default: "pending" # pending|pending_approval|approved|denied|completed|failed
      t.json :input
      t.json :output
      t.datetime :resolved_at # when a human approved/denied/answered
      t.json :resolved_by     # the resolving principal
      t.timestamps

      t.index [ :turn_id, :tool_call_id ], unique: true
    end

    create_table :xeno_events do |t|
      t.references :session, null: false, foreign_key: { to_table: :xeno_sessions }
      t.integer :index, null: false # per-session cursor (SSE start_index)
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
  end
end
