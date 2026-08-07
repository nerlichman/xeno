class AddStateToXenoSessions < ActiveRecord::Migration[8.1]
  def change
    # The session-scoped KV store (Session#state / Tool#state): JSON-typed
    # values, survives restarts, never crosses sessions, cleared by reset.
    # Working state for one conversation — NOT long-term memory.
    add_column :xeno_sessions, :state, :json, null: false, default: {}
  end
end
