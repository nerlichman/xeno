# The runtime, precisely

This document is shipped inside the gem so coding agents (and curious humans) can read
how the durability machinery actually works. The README sells it; this explains it.

## Objects

- **Session** (`xeno_sessions`) — the durable conversation. Statuses:
  `running | waiting | completed | failed`. Owns one transcript chat, the turn ledger,
  the event stream, and at most one `continuation_token` (channel-owned resume handle,
  unique among ACTIVE sessions). A session stays active indefinitely — turns finishing
  never retire it; **`reset` is the only terminal transition**, and it nulls
  the token (audit copy in `metadata`) so the same handle can start fresh. The
  `failed` status and `session.failed` event are reserved (never produced today).
- **Turn** (`xeno_turns`) — one user message (or several, when queued messages fold)
  and all work until the agent responds. One ActiveJob. Statuses:
  `pending | running | waiting | completed | failed | cancelled`.
- **Action** (`xeno_actions`) — one requested tool call: the durability checkpoint and
  the approval state. `completed` means "executed AND its result row is in the
  transcript" — both commit in one transaction.
- **Event** (`xeno_events`) — append-only, per-session dense `index` starting at 0.
  The SSE cursor and the audit log are the same rows.
- **Transcript** — RubyLLM's acts_as integration: xeno owns the chat and message
  rows (`xeno_chats`, `xeno_messages`); RubyLLM owns tool calls, the model
  registry, per-attempt usage, and batches as library records on its own tables
  (`ruby_llm_tool_calls`, `ruby_llm_models`, `ruby_llm_usages`,
  `ruby_llm_batches`), polymorphic toward xeno's classes. No duplication above them.

## The turn loop (TurnRunner)

```
claim! (CAS) → clean crash artifacts → loop:
  unanswered tool calls?  → replay recorded / inject denials / gate / execute
  complete?               → finish
  otherwise               → generate (one model call, step budget, heartbeat)
```

Rules inherited from the RubyLLM v2 investigation (each empirically verified):

1. Never `complete` (a turn must bound its model calls) or `run_tools` (no approval
   gate, no per-call action checkpoint). The runner IS the loop.
2. A killed process leaves a blank assistant row (`before_message` persists it before
   the HTTP call) that makes `complete?` read true — trailing blank assistant rows are
   deleted on entry.
3. Tool results are injected via Rails `add_message`, which persists every column the
   message model carries — thinking, citations, reasoning and the raw provider
   content all survive the round trip.
4. `assume_model_exists` and `protocol` are not persisted; the runner re-applies them
   from the definition on a pristine record every run.

## Claims, fencing, ordering

- **Claim** — single-statement CAS: bump `claim_token` where
  `status='pending' OR (running AND heartbeat stale)`, and no earlier non-terminal
  turn exists in the session (turns run in order). One row updated = you own it.
- **Heartbeat** — touched at step boundaries, and kept alive DURING model calls and
  tool bodies by a sibling beater thread (`config.heartbeat_interval`, default a
  quarter of `turn_stale_after`) — a live-but-slow call is never reclaimed
  mid-flight. `Xeno.config.turn_stale_after` (default 5 min) is the dead-worker
  takeover window.
- **Graceful shutdown** — between steps the runner probes
  `config.stopping_check` (default: `queue_adapter.stopping?`, which Solid Queue
  flips when a worker begins stopping). A stopping worker releases the claim
  (status back to `pending`, no `attempts` bump) and re-enqueues the turn, so a
  deploy resumes on the next worker within seconds instead of waiting out the
  staleness window.
- **Fencing** — **turn-row writes** (status transitions, heartbeats, the step budget)
  are `WHERE claim_token = mine`; a reaped zombie fails there and aborts via
  `Xeno::Fenced`. Event/action/transcript writes are NOT individually fenced — a
  zombie that dies mid-step can leave a duplicate event or an extra tool-result row,
  which replay and `(session, index)` dedupe absorb. No fencing probe runs inside a
  model call; a fenced-out runner notices at the next turn-row write.
- **Poison guard** — `attempts >= max_turn_attempts` fails the turn at claim time.
  `attempts` counts failures only (transient errors, crash reclaims); approval
  resumes are counted apart (`resumes`) and are unbounded.
- **Reaper** — `Xeno::Reaper.sweep!` (ReaperJob, every minute via Solid Queue
  recurring; `bin/rails xeno:reap` on other backends) re-enqueues turns with no live
  owner: stale `running` (dead worker, exhausted queue retries), stale `pending`
  (lost job), and `waiting` turns whose every action is resolved (a crash between
  resolve and resume-enqueue). Genuinely parked turns are never touched; duplicates
  are harmless because the claim CAS decides ownership.
- **Chaining** — queued messages drain into ONE staged next turn when the session
  parks or the turn goes terminal (and immediately for messages sent to an
  already-parked session). Drained turns DEFER their transcript: the user rows are
  written when the runner claims the turn (append + fenced flag flip in one
  transaction — exactly-once), so a parked turn's unanswered tool calls are never
  separated from their results. A terminal turn enqueues the next pending turn
  (later turns can't claim past an active earlier one).

## Parking

A blocking action (unapproved gated tool, unanswered `ask_question`) flips the action
to `pending_approval`, emits `input.requested`, sets turn + session to `waiting`, and
the job returns. Nothing waits. `Xeno::Inputs.approve!/deny!/answer!` stamp
`resolved_at/resolved_by` and enqueue the resume — only once no blocker remains
(resuming with partial tool results is an invalid provider state). Resolution, the
status flip, and the resume enqueue commit in ONE transaction — on a DB-backed queue
(Solid Queue) a crash can never separate "approved" from "job exists"; on other
backends the reaper's sweeps recover the orphan.

Ungated calls in a mixed batch execute (and are recorded) before the park; the resume
replays them for free. Schedule sessions never park — a blocker deterministically
fails the turn (`schedule runs cannot wait for human input`).

Cancellation is cooperative: the persisted `cancelled` flag is polled by RubyLLM's
checker at loop boundaries — and since the runner does NOT stream, a cancel
takes effect at the next STEP boundary, which can mean waiting out an in-flight model
call. A parked turn cancels instantly (its dangling tool calls are settled with
denial results first, so the session keeps chatting).

**Steering** (`steer: true` on the messages endpoint, the dev UI's checkbox, or
`Session#steer!`): stop the active turn and make THIS message the next one. A parked
or pending turn settles (recorded answers injected, unapproved gates denied) and
cancels immediately, and the steer message stages at once; a running turn cancels
cooperatively with the steer message queued — the cancel path folds it into the next
turn. If the cancel loses the race with a completing turn, steering degrades to a
normal follow-up. A steered-away pending turn keeps its unsent messages in
`turns.user_message` for audit.

## Events

Envelope: `{ type, data, meta: { index, at } }`. Emission is race-safe (unique index +
retry). Re-emission after a replayed step appends new indexes — consumers dedupe by
`(session, index)`. Vocabulary:

```
session.started  turn.started    message.received
step.started     step.completed  step.failed
actions.requested action.result  input.requested
reasoning.completed message.completed
compaction.requested compaction.completed
budget.exceeded
turn.completed   turn.failed     turn.cancelled
session.waiting  session.completed session.failed
```

Notes: `step.failed` fires when a tool raises (the error becomes the action result);
`session.completed` fires on `reset` (the only session-terminal transition);
`session.failed` is reserved — nothing emits it yet. Live streaming deltas are not
part of this release — `message.completed` is the durable completion signal.
`compaction.requested` fires when a compaction turn is staged (auto: with
`used`/`limit`; manual: reason only); `compaction.completed` commits atomically with
the rewritten transcript and carries `compacted_messages` (0 = nothing to compact).

## Hooks

`agent/hooks/*.rb` — observe-only handlers for stream events:

```ruby
Xeno.hook "turn.completed" do |event|
  Metrics.increment("agent.turns")  # event: event_type, data, index, session
end

Xeno.hook "*" do |event| ... end    # every event
```

Handlers fire AFTER the event row commits (never inside the emitting
transaction), typed handlers before the wildcard. They are observe-only: return
values are ignored, nothing can be vetoed, no model context can be injected, and
a raising handler is logged and skipped — a hook can never break the runtime
or fail the turn.

**Hooks are at-least-once.** Replayed steps re-emit new events with new indexes.
Key once-per-step side effects on `(turn_id, step)` from the event data; key
stored content on `(session_id, index)`.

## Budgets

Per-session token caps, enforced BEFORE each model call from the persisted
per-attempt usage ledger (`ruby_llm_usages` — the provider's own counts,
summed across every attempt of the session's chat, retries included). Input and
output are checked independently; the call that crosses a cap is allowed to
finish — the NEXT call trips, raising a deterministic `turn.failed` preceded by a
`budget.exceeded` event (`axis`, `used`, `limit`). The session stays `running`
and later turns fail the same way until `reset` retires it (a fresh session has
fresh usage).

The ledger survives compaction: compacting a session shrinks its context, never
its counted spend. (Before the ledger, usage lived on message rows and compaction
destroyed them — sessions could compact their way back under a budget. That was
accidental; cost already incurred stays counted.)

Configuration: global `config.max_input_tokens_per_session` /
`config.max_output_tokens_per_session` (nil = unlimited); per-agent override in
agent.rb via `limits input_tokens:, output_tokens:` (`false` disables an axis
even when a global cap exists). The compaction summarizer's own call is not chat
usage and does not count against the caps.

## Session state

`Session#state` (and `state` inside any `Xeno::Tool` body) is the per-session KV
store: `get`/`[]`, `update` (locked merge), `set`, `delete`, `to_h`. Values are
JSON-typed — symbols stringify, unserializable values raise `Xeno::Error` before
anything is written. Reads always hit the database, so a tool running in a fresh
worker sees what the last worker wrote; state survives restarts and `kill -9`
because it is just a column (`xeno_sessions.state`). It never crosses sessions and
`reset` clears it.

**This is working state for one conversation, not long-term memory.** Anything
that should outlive the session (user preferences, learned facts) belongs in your
own models — a tool can read and write those directly.

## Instructions

The system prompt refreshes at every turn stage (deploy semantics — the next turn
picks up edits). Two composable sources under `agent/`:

- `instructions.md` — the static always-on prompt.
- `instructions.rb` — `Xeno.instructions do |context| … end`, resolved fresh at
  every turn stage with `context.session` and `context.principal` (the
  current_user use case). The block's return is appended after the markdown,
  separated by a blank line. Either file alone is sufficient; both compose.
  A block that raises at resolve time logs a warning and the turn proceeds on the
  static instructions — dynamic instructions can degrade, never brick. Keep the
  block fast: it runs on every turn.

## Compaction

Long transcripts are compacted **between turns** by summarize-and-replace:

- **Trigger** — after a message turn completes, when the last model call's persisted
  usage (`input_tokens + output_tokens` of the newest succeeded ledger entry) crosses
  `compaction_threshold` (default 0.9) × the model's context window. The window comes
  from the model registry; for models the registry doesn't know
  (`assume_model_exists`) set `config.compaction_context_window` or automatic
  compaction never triggers. `compaction_threshold = nil` disables auto entirely.
  Manual trigger: `POST /v1/sessions/:id/compact` (202; 409 if one is already
  queued) or the dev UI's "Compact transcript" button.
- **Execution** — compaction runs as a turn (`kind: "compaction"`) under a normal
  claim: it is exclusive by CAS, queues behind an active or parked turn via session
  ordering, heartbeats through the summary model call, and replays crash-safely (the
  applied result is recorded on the turn row; a replay past the commit is a no-op).
  It never appends a synthetic user message.
- **Shape** — the system prompt survives; the newest `compaction_tail_turns`
  (default 2) user-anchored turns survive verbatim (the cut lands on a user row, so
  tool calls are never separated from their results); everything earlier is
  summarized by a throwaway call to the active model and REPLACED — the summary is
  written into the earliest compacted row (id/created_at ordering both keep it in
  place) as a `[Conversation summary — …]` user row.
- **Caveats** — the summary call sends the compacted span verbatim (no per-message
  truncation), so pathologically large single messages can stress the summarizer's
  own window. Compacted content is gone from the transcript; the events and action
  rows remain the audit trail.

Instrumentation spans: `xeno.turn`, `xeno.step`, `xeno.action`
(ActiveSupport::Notifications).

## Authorization

Authentication (the configured lambda) answers "who is this"; **ownership** answers
"whose session is this". The rule:

- A session belongs to the **principal stamped at create** (the lambda's return value
  for HTTP, the Slack sender for Slack, the app principal for schedules).
- Every session-scoped endpoint (`messages`, `inputs`, `cancel`, `reset`, `stream`)
  compares the caller's principal to the stored one; a mismatch is the same **404** as
  a nonexistent id — existence is not leaked.
- A lambda that returns bare `true` yields nil principals everywhere: **single-tenant
  mode**, every authenticated caller matches every session. Return a real identity to
  get per-principal isolation.
- Development with no lambda configured uses a fallback dev principal that matches
  everything — development only, and only via the fallback (a configured lambda is
  always enforced).

Continuation tokens are compared timing-safely. Client-supplied tokens on create are
restricted to the reserved `http:` namespace — channel namespaces (`slack:…`) are
minted only by their channels, so a crafted token cannot hijack another channel's
thread.

## Channels

`Xeno::Channels` maps `session.channel` to a registered channel object with two
delivery hooks — `deliver_completion(session, content)` at turn completion and
`deliver_input_request(session, actions)` at park. Delivery failures log and move on:
the durable truth is rows, and the event stream replays everything.
