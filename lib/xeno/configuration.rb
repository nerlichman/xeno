# frozen_string_literal: true

module Xeno
  # Gem-level runtime knobs, set from an initializer:
  #
  #   Xeno.configure do |config|
  #     config.max_steps = 30
  #   end
  #
  class Configuration
    # Per-turn model-call budget (RubyLLM's own loop is unbounded; ours is not).
    attr_accessor :max_steps

    # A turn whose claim ledger reaches this many attempts is poison — it
    # fails instead of retrying forever.
    attr_accessor :max_turn_attempts

    # A running turn whose heartbeat is older than this is presumed dead and
    # reclaimable. Checkpoint replay makes takeover safe; a too-short window
    # risks overlap with a live-but-slow owner, a too-long one stalls the
    # session after a hard crash.
    attr_accessor :turn_stale_after

    # How often the background heartbeat beats while the runner is inside a
    # model call or a tool body (the calls that can outlast turn_stale_after).
    # nil (default) = a quarter of turn_stale_after, so a live owner always
    # beats several times per staleness window.
    attr_writer :heartbeat_interval

    # Per-session token budgets, enforced BEFORE each model call from the
    # persisted usage columns (the provider's own counts). Checked
    # independently per axis; the call that crosses is allowed to finish —
    # the NEXT call trips. Exceeded → deterministic turn failure with a
    # budget.exceeded event; the session recovers via reset. nil =
    # unlimited. Per-agent override: `limits input_tokens:, output_tokens:`
    # in agent.rb (false disables an axis).
    attr_accessor :max_input_tokens_per_session, :max_output_tokens_per_session

    # Compaction triggers when the last model call's context usage crosses
    # this fraction of the model's context window. nil/false
    # disables automatic compaction (manual stays available).
    attr_accessor :compaction_threshold

    # Fallback context window (tokens) for models the registry doesn't know
    # (assume_model_exists). nil = automatic compaction never triggers for
    # unknown-window models.
    attr_accessor :compaction_context_window

    # How many of the most recent user-message-anchored turns survive a
    # compaction verbatim (the "recent tail"). Everything earlier is
    # summarized and replaced.
    attr_accessor :compaction_tail_turns

    # Optional lambda answering "is the worker shutting down?" — probed by
    # the runner between steps; when true the turn releases its claim and
    # re-enqueues itself so a deploy-style stop resumes promptly on the next
    # worker instead of waiting out stale-heartbeat reclaim. nil = ask the
    # queue adapter (`queue_adapter.stopping?` — Solid Queue flips it on
    # worker shutdown; adapters that don't implement it just return false).
    attr_accessor :stopping_check

    # Fail-closed HTTP auth lambda. Receives the request; a falsy return is
    # a 401; a truthy return becomes the request principal.
    attr_accessor :authenticate

    # How often the SSE stream polls for new events, in seconds.
    attr_accessor :stream_poll_interval

    # How many events one stream poll reads at most. Bounds the catch-up
    # read on long sessions (a reconnect from index 0 pages through history
    # in batches instead of loading every row in one query).
    attr_accessor :stream_catch_up_batch

    # Optional hard cap on how long one SSE connection is served (seconds).
    # nil = until the session reaches a terminal status.
    attr_accessor :stream_max_duration

    # Optional lambda answering "is the server shutting down?" — when true,
    # open SSE streams close themselves so a graceful stop doesn't wait out
    # the in-flight-request window (Ctrl-C stays near-instant with tabs
    # open). nil = detect Puma's graceful stop automatically.
    attr_accessor :stream_shutdown_check

    def initialize
      @max_steps = 20
      @max_turn_attempts = 5
      @turn_stale_after = 5 * 60 # seconds
      @heartbeat_interval = nil
      @max_input_tokens_per_session = nil
      @max_output_tokens_per_session = nil
      @compaction_threshold = 0.9
      @compaction_context_window = nil
      @compaction_tail_turns = 2
      @stopping_check = nil
      @authenticate = nil
      @stream_poll_interval = 0.25
      @stream_catch_up_batch = 500
      @stream_max_duration = nil
      @stream_shutdown_check = nil
    end

    def turn_stale_after
      @turn_stale_after.is_a?(Numeric) ? @turn_stale_after.seconds : @turn_stale_after
    end

    def heartbeat_interval
      @heartbeat_interval || turn_stale_after / 4.0
    end
  end

  class << self
    def config
      @config ||= Configuration.new
    end

    def configure
      yield config
    end
  end
end
