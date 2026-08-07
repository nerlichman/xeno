class AddTranscriptDeferredToXenoTurns < ActiveRecord::Migration[8.1]
  def change
    # A deferred turn's user messages live in turns.user_message until the
    # runner claims it and writes them into the transcript (drained turns
    # must not mutate a parked turn's mid-flight transcript).
    add_column :xeno_turns, :transcript_deferred, :boolean, null: false, default: false
  end
end
