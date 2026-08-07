module Xeno
  class Error < StandardError; end

  # Raised when a fenced write discovers its claim was reaped — the runner
  # is a zombie and must abort without touching anything else.
  class Fenced < Error; end

  # Raised (internally) to park the turn: pending actions need human input.
  # Never RubyLLM's cancel! — its cleanup destroys in-flight rows.
  class Parked < Error
    attr_reader :actions

    def initialize(message = "turn parked awaiting input", actions: [])
      super(message)
      @actions = actions
    end
  end

  # The per-turn runaway guard tripped.
  class MaxStepsExceeded < Error; end

  # A session token budget is spent: raised BEFORE the model call that
  # would overspend. Deterministic turn failure; reset recovers the session.
  class BudgetExceeded < Error
    attr_reader :axis, :used, :limit

    def initialize(axis:, used:, limit:)
      @axis = axis
      @used = used
      @limit = limit
      super("session #{axis} token budget exceeded (#{used}/#{limit})")
    end
  end

  # Raised (internally) between runner steps when the worker is shutting
  # down gracefully: the turn releases its claim and re-enqueues itself so
  # the next worker resumes it promptly (the AJ Continuation checkpoint
  # pattern). Not a failure — it never counts against the poison ladder.
  class Interrupted < Error; end
end
