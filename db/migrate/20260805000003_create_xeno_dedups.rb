class CreateXenoDedups < ActiveRecord::Migration[8.1]
  def change
    # At-least-once delivery dedup ledger: schedule ticks, Slack event ids.
    # One row per (scope, key); the unique index is the arbiter.
    create_table :xeno_dedups do |t|
      t.string :scope, null: false
      t.string :key, null: false
      t.json :metadata
      t.datetime :created_at, null: false

      t.index [ :scope, :key ], unique: true
    end
  end
end
