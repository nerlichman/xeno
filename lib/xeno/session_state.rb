# frozen_string_literal: true

module Xeno
  # The per-session KV store: working state for one conversation, not long-term memory. Values
  # round-trip through JSON (symbols become strings; unserializable values are rejected up front).
  # Reads always hit the database, and writes take the session row lock so read-modify-write merges
  # never lose entries. Cleared by `reset`.
  class SessionState
    def initialize(session)
      @session = session
    end

    def get(key)
      current[key.to_s]
    end
    alias [] get

    def to_h
      current
    end

    # Merges the entries in one locked write. Keys stringify; values must be JSON-serializable
    # (Xeno::Error otherwise).
    def update(entries)
      normalized = normalize(entries)
      @session.with_lock do
        @session.update!(state: (@session[:state] || {}).merge(normalized))
      end
      self
    end

    def set(key, value)
      update(key => value)
    end
    alias []= set

    def delete(key)
      @session.with_lock do
        @session.update!(state: (@session[:state] || {}).except(key.to_s))
      end
      self
    end

    private

    def current
      Session.where(id: @session.id).pick(:state) || {}
    end

    def normalize(entries)
      JSON.parse(JSON.generate(entries.to_h))
    rescue TypeError, JSON::GeneratorError, NoMethodError => e
      raise Xeno::Error, "session state values must be JSON-serializable: #{e.message}"
    end
  end
end
