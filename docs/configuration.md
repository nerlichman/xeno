# Configuration reference

Every knob on `Xeno.configure`. Standalone apps configure in `agent/agent.rb`;
mounted apps use `config/initializers/xeno.rb`. The mechanics behind these knobs
— claims, heartbeats, budget and compaction semantics — are documented in
[runtime.md](runtime.md).

```ruby
Xeno.configure do |config|
  config.max_steps = 20
  config.turn_stale_after = 5.minutes
end
```

## The turn loop

| Setting | Default | Meaning |
|---|---|---|
| `max_steps` | `20` | Per-turn model-call budget. |
| `max_turn_attempts` | `5` | Attempts before a turn is declared poison and fails. |
| `turn_stale_after` | `5.minutes` | A running turn with an older heartbeat is presumed dead and reclaimable. |
| `heartbeat_interval` | a quarter of `turn_stale_after` | Heartbeat cadence during model calls and tool bodies. |

## Budgets

| Setting | Default | Meaning |
|---|---|---|
| `max_input_tokens_per_session` | `nil` (unlimited) | Per-session input-token budget. |
| `max_output_tokens_per_session` | `nil` (unlimited) | Per-session output-token budget. |

Per-agent override in `agent.rb`: `limits input_tokens:, output_tokens:`
(`false` disables an axis).

## Compaction

| Setting | Default | Meaning |
|---|---|---|
| `compaction_threshold` | `0.9` | Fraction of the context window that triggers automatic compaction. `nil`/`false` disables it; manual stays available. |
| `compaction_context_window` | `nil` | Fallback window (tokens) for models the registry doesn't know. `nil`: automatic compaction never triggers for them. |
| `compaction_tail_turns` | `2` | Recent turns kept verbatim through a compaction. |

## HTTP and streaming

| Setting | Default | Meaning |
|---|---|---|
| `authenticate` | `nil` | Fail-closed auth lambda: falsy return is a 401, truthy becomes the request principal. |
| `stream_poll_interval` | `0.25` | Seconds between event-stream polls. |
| `stream_catch_up_batch` | `500` | Max events per poll; bounds catch-up reads on long sessions. |
| `stream_max_duration` | `nil` | Hard cap (seconds) on one stream connection. `nil`: until the session ends. |
| `stream_shutdown_check` | `nil` | Lambda: "is the server shutting down?" — open streams close when true. `nil` detects Puma's graceful stop. |

## Deploys

| Setting | Default | Meaning |
|---|---|---|
| `stopping_check` | `nil` | Lambda: "is the worker shutting down?" — probed between steps; a true return releases the claim and re-enqueues. `nil` asks the queue adapter. |
