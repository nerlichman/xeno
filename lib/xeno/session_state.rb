module Xeno
  # The per-session KV store: working state for
  # ONE conversation. JSON-typed — values round-trip through JSON, so
  # symbols become strings and anything unserializable is rejected up
  # front. Reads always hit the database (a tool in a fresh worker sees
  # what the last worker wrote); writes take the session row lock, so
  # read-modify-write merges never lose entries. Cleared by `reset`; it is
  # NOT long-term memory — durable knowledge belongs in your own models.
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

    # Merges the entries in one locked write. Keys stringify; values must
    # be JSON-serializable (Xeno::Error otherwise).
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
