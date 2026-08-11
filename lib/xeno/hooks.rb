# frozen_string_literal: true

module Xeno
  # Observe-only event handlers from agent/hooks/*.rb:
  #
  #   Xeno.hook "turn.completed" do |event|
  #     Metrics.increment("agent.turns", tags: [event.session.channel])
  #   end
  #
  #   Xeno.hook "*" do |event| ... end   # every event
  #
  # Semantics:
  # - Handlers fire AFTER the event row is durably committed (after_commit),
  #   typed handlers first, then the wildcard. The block receives the
  #   Xeno::Event record (event_type, data, index, session).
  # - Observe-only: return values are ignored; hooks cannot veto anything
  #   or inject model context. A raising handler is logged and skipped — a
  #   hook can never break the runtime or fail the turn.
  # - AT-LEAST-ONCE: replayed steps re-emit new events with new indexes.
  #   Key once-per-step side effects on (turn_id, step) from the data; key
  #   stored content on (session_id, index).
  module Hooks
    module_function

    def dispatch(event, definition: Xeno.definition)
      hooks = definition.respond_to?(:hooks) ? definition.hooks : {}
      return if hooks.empty?

      handlers = Array(hooks[event.event_type]) + Array(hooks["*"])
      handlers.each do |handler|
        handler.call(event)
      rescue StandardError => e
        Rails.logger.warn(
          "xeno: hook for #{event.event_type} raised #{e.class}: #{e.message} — hooks are observe-only, continuing"
        )
      end
    end
  end
end
