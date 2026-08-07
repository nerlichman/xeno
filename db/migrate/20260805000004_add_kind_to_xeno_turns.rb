class AddKindToXenoTurns < ActiveRecord::Migration[8.1]
  def change
    # "message" turns drive the model loop; "compaction" turns
    # summarize-and-replace the transcript. Compaction rides the turn
    # machinery so it inherits the claim CAS, session ordering (it queues
    # behind an active or parked turn), heartbeat, and crash-safe replay.
    add_column :xeno_turns, :kind, :string, null: false, default: "message"
  end
end
