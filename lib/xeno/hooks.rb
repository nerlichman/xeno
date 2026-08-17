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
  # Handlers fire after the event row commits, typed handlers before the wildcard, with the
  # Xeno::Event record as the argument. Return values are ignored and a raising handler is logged
  # and skipped — a hook can never veto, inject context, or fail the turn. Delivery is
  # at-least-once: replayed steps re-emit events, so key side effects on (turn_id, step) and stored
  # content on (session_id, index).
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
