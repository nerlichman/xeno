module Xeno
  # The append-only session stream — also the audit log. `index` is the
  # per-session cursor; consumers dedupe
  # re-emitted events by (session, index).
  class Event < ApplicationRecord
    belongs_to :session, class_name: "Xeno::Session"

    # The fixed vocabulary (docs/runtime.md § Events). Hooks may subscribe
    # to any of these or "*".
    TYPES = %w[
      session.started turn.started message.received
      step.started step.completed step.failed
      actions.requested action.result input.requested
      reasoning.completed message.completed
      compaction.requested compaction.completed
      budget.exceeded
      turn.completed turn.failed turn.cancelled
      session.waiting session.completed session.failed
    ].freeze

    # Hooks fire only after the row is durably committed (and therefore
    # visible to other processes) — never inside the emitting transaction.
    after_create_commit { Hooks.dispatch(self) }

    # Appends with a race-safe per-session index: concurrent writers collide
    # on the unique index and retry with the next slot. The INSERT runs in
    # its own savepoint (requires_new): emit is routinely called inside
    # enclosing transactions, and on Postgres a failed INSERT otherwise
    # aborts the whole transaction — the retry would raise
    # PG::InFailedSqlTransaction instead of recovering.
    def self.append!(session, event_type, data = {})
      attempts = 0
      begin
        next_index = (where(session_id: session.id).maximum(:index) || -1) + 1
        transaction(requires_new: true) do
          create!(
            session_id: session.id,
            index: next_index,
            event_type: event_type,
            data: data,
            created_at: Time.current
          )
        end
      rescue ActiveRecord::RecordNotUnique
        # Every collision means a competing append SUCCEEDED, so retries are
        # bounded by actual contention. SQLite's file lock serializes writers
        # (collisions are rare); Postgres runs them truly concurrently, so a
        # burst can cost more than a handful of rounds — back off with jitter
        # instead of giving up early.
        attempts += 1
        raise if attempts >= 50

        sleep(rand * 0.002 * attempts)
        retry
      end
    end

    # The wire envelope: { type, data, meta: { index, at } }.
    def envelope
      { "type" => event_type, "data" => data || {}, "meta" => { "index" => index, "at" => created_at.iso8601(3) } }
    end
  end
end
