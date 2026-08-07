# xeno

**RubyLLM gives you the conversation; xeno gives you the agent** — a session that
survives deploys mid-turn, waits days for a human approval without holding a process,
and resumes exactly where it stopped.

xeno is a framework for durable AI agents. Built on Rails, runnable standalone
(`xeno new my-agent`) or inside the Rails app you already have.

Under the hood it composes [RubyLLM](https://rubyllm.com) (model calls), ActiveJob +
ActiveRecord (durability), and Rails (HTTP) — the same shape
[eve](https://vercel.com/blog/eve) built on the AI SDK, the Workflow SDK, and Nitro,
on the machinery Ruby already trusts.

## The demo

```bash
bundle add xeno
bin/rails g xeno:install     # agent/ appears at your app root
bin/rails g xeno:tool ChargeCard
```

```ruby
# agent/tools/charge_card.rb — ten lines, full Rails access
class Xeno::Tools::ChargeCard < Xeno::Tool
  description "Charge the customer's card. Irreversible."
  parameter :amount_cents, type: :integer, description: "Amount in cents"

  approval :always   # ← the human-in-the-loop gate

  def execute(amount_cents:)
    PaymentService.charge!(amount_cents) # your domain code, right here
  end
end
```

Now the moment durability stops being a claim:

1. Send a message over HTTP → the agent decides to charge → **the turn parks**.
   No process is waiting; the pending approval is a database row.
2. `kill -9` the worker. Deploy. Go home for the weekend.
3. Restart, approve (HTTP, or one click in the dev UI at `/agent/dev`) →
   **the turn resumes exactly where it stopped**, the tool runs exactly once,
   and the final answer arrives — with the whole story in the event stream:

```
session.started → message.received → turn.started → step.started → step.completed
→ actions.requested → input.requested → session.waiting        [kill -9 here]
→ action.result → step.started → step.completed → message.completed → turn.completed
```

This exact arc is the flagship integration test (`test/demo_acceptance_test.rb`, three
real processes) and a watchable script (`script/demo.sh`).

## Two ways in

> [!WARNING]
> xeno currently tracks **RubyLLM v2 (unreleased)**, pinned to git ref
> [`2aaddf96`](https://github.com/crmne/ruby_llm/commit/2aaddf96) — the released
> `ruby_llm` gem (1.16.0) is **not compatible**. Standalone apps get the pin from
> the scaffold's Gemfile. **Mounted mode: if your Rails app already uses a released
> `ruby_llm`, xeno will not work alongside it today** — you'd have to move your app
> to the pinned ref, which has breaking changes (notably a restructured ActiveRecord
> integration). This resolves at RubyLLM v2 GA, when xeno switches to the released gem.

**Standalone** — build an agent from nothing; Rails is an implementation detail you
never see (the entire `Rails::Application` lives inside the gem):

```bash
xeno new my-agent && cd my-agent
bundle install
xeno server        # web + Solid Queue in ONE process, sqlite, zero services
```

```text
my-agent/
├── agent/            # agent.rb, instructions.md, tools/
├── AGENTS.md         # points coding agents at the gem's docs (CLAUDE.md includes it)
├── Gemfile
├── config.ru         # require "xeno/standalone"; run Xeno.rails_app
└── .gitignore
```

**Mounted (existing app)** — the structural advantage no external agent platform can
match: your tools *are* your domain code. Models, policies,
`Rails.application.credentials` — no connectors needed to reach your own data.

```bash
bundle add xeno && bin/rails g xeno:install
```

## The agent directory

The path supplies the name — no `name:` fields anywhere. `bin/rails xeno:info` prints
the resolved agent with diagnostics for anything misplaced.

```
agent/
├── agent.rb            # optional: model + runtime config
├── instructions.md     # the always-on system prompt
├── instructions.rb     # optional: dynamic instructions, resolved per turn
├── tools/
│   └── get_weather.rb  # → tool "get_weather" (Xeno::Tools::GetWeather)
├── hooks/
│   └── metrics.rb      # → observe-only event handlers (at-least-once)
└── schedules/
    └── weekly_recap.md # → cron-triggered agent session
```

```ruby
# agent/agent.rb
Xeno.agent do
  model "claude-sonnet-4-6"        # any RubyLLM model id; options pass through
end

# agent/instructions.rb — the current_user use case: resolved at every turn
# stage with the session context, appended after instructions.md.
Xeno.instructions do |context|
  user = User.find_by(id: context.principal&.dig("user_id"))
  "You are assisting #{user&.name || 'a guest'} (plan: #{user&.plan || 'none'})."
end
```

Tool approval policies: `:never` (default), `:once` (per session), `:always`, or a
lambda receiving the session's principal:

```ruby
approval ->(ctx) { ctx.principal&.dig("role") != "admin" }
```

Inside a tool body, `state` is the session-scoped KV store — JSON values that
survive restarts, never cross sessions, and are cleared by `reset` (working
state, not long-term memory):

```ruby
def execute(city:)
  state.update("last_city" => city, "lookups" => state.get("lookups").to_i + 1)
  { city: city, condition: "Sunny" }
end
```

One framework tool ships built in: `ask_question` — the model asking your human a
question parks the turn with the same mechanics as approvals.

## How it works

Work nests **session → turn → step** (eve's model). A turn is one ActiveJob; a step is
one model call plus its tool calls, checkpointed in your database:

- The runner drives RubyLLM v2's decomposed loop (`generate` + self-executed tools +
  result injection) — never the unbounded `complete`, never the non-idempotent
  `run_tools`.
- A tool execution and its transcript injection commit in one transaction: **recorded
  calls are never re-executed**. A killed process resumes from the last checkpoint.
- Correctness lives in the database, not the queue: atomic claim (CAS), heartbeats with
  stale-claim takeover, fencing tokens (a zombie worker's turn-state writes hit zero
  rows; see docs/runtime.md for the exact fencing scope), a max-attempts poison guard,
  and a reaper that re-enqueues turns with no live owner. Any ActiveJob backend works;
  Solid Queue makes the whole story "a database row."
- Parking = the job *ends*. A parked session costs nothing for hours or days; input
  resolution enqueues the resume.
- Messages arriving mid-turn queue up and fold into the next turn automatically.

## HTTP API (engine mounts at `/agent`)

```
POST /agent/v1/sessions                    → { session_id, continuation_token }
POST /agent/v1/sessions/:id/messages       → follow-up (requires continuation_token; steer: true replaces the active turn)
POST /agent/v1/sessions/:id/inputs         → approve / deny / answer (by action_id)
POST /agent/v1/sessions/:id/cancel         → stop the active turn (session intact)
POST /agent/v1/sessions/:id/compact        → summarize-and-replace old history (queues behind the active turn)
POST /agent/v1/sessions/:id/reset          → retire the session, release its token
GET  /agent/v1/sessions/:id/stream         → SSE (or ?format=ndjson); ?start_index=N rewinds/resumes
GET  /agent/v1/health
POST /agent/v1/dev/schedules/:name         → dev-only manual dispatch
GET  /agent/dev                            → dev chat UI (development only)
```

Events are append-only rows with a per-session index — the stream replays from any
cursor, and the table doubles as your audit log.

## Slack

Two credentials and the agent answers mentions in threads:

```ruby
# agent/channels/slack.rb
Xeno.channel :slack do
  signing_secret Rails.application.credentials.dig(:slack, :signing_secret)
  bot_token     Rails.application.credentials.dig(:slack, :bot_token)
end
```

Point your Slack app's Events API at `POST /agent/v1/channels/slack/events`
(signatures verified in constant time; the handshake is handled; retries are deduped
by event_id and acked inside Slack's 3s window). Mentions and DMs start sessions;
each Slack thread is one session; replies continue it. When the agent parks, the
approval prompt lands in the thread — reply **approve**, **deny**, answer a
free-form question with any text, or pick a choice by number ("2") or label
("tuesday"); unrelated replies are held as the next message, never treated as a
resolution. Replies post at turn completion by default; opt into post-then-edit
streaming with `stream_replies true` in the channel block (~1s edit cadence,
rate-limit aware).

## Schedules

```markdown
---
cron: "0 9 * * 1"
---
Summarize the week's activity and post highlights to the team.
```

`bin/rails xeno:schedules:sync` compiles `agent/schedules/*.md` into Solid Queue
recurring entries (dev never fires on cadence; trigger by name via the dev endpoint).
Schedule runs execute under the app principal and **cannot** wait on a human — a
gated tool deterministically fails the run.

## Configuration

```ruby
# config/initializers/xeno.rb
Xeno.configure do |config|
  # FAIL-CLOSED: every endpoint (except health) is 401 until you set this.
  # The truthy return value becomes the session principal.
  config.authenticate = ->(request) do
    token = request.headers["Authorization"]&.delete_prefix("Bearer ")
    { "user" => "api" } if ActiveSupport::SecurityUtils.secure_compare(
      token.to_s, Rails.application.credentials.xeno_api_key.to_s
    )
  end

  config.max_steps = 20               # per-turn model-call budget
  config.turn_stale_after = 5.minutes # dead-worker takeover window
end
```

(Development with no lambda configured stays usable on localhost — everywhere else the
absence of a checker is a 401.)

### Model registry

Model ids resolve against RubyLLM's registry, and models released after the gem's
catalog snapshot need a registry refresh before they resolve. Standalone apps do
this automatically on first boot (right after the boot-time migrations; skip with
`XENO_SKIP_MODEL_REFRESH=1`). To refresh later — say a provider ships a new model —
run it manually for now (a friendlier command is planned):

```bash
# mounted
bin/rails runner "RubyLLM.models.refresh!"
```

```bash
# standalone
bundle exec ruby -r dotenv/load -r xeno/standalone -e 'Xeno.rails_app; Xeno.definition; RubyLLM.models.refresh!'
```

Or bypass the registry per model: `model "the-id", provider: :openai, assume_model_exists: true`
(automatic compaction then needs `config.compaction_context_window`, since the
registry can't supply the window).

The principal is also the **ownership** boundary: a session belongs to the principal
stamped at create, and every session-scoped endpoint 404s for any other principal. A
lambda that returns bare `true` (no identity) makes every authenticated caller match
every session — fine for single-tenant mounts, but return a real identity for
per-principal isolation. See `docs/runtime.md` § Authorization.

## Security posture — read this

xeno's trust model is **inverted from eve's, on purpose**: eve sandboxes model-driven
execution away from your app; xeno's flagship feature is tools that touch domain code
directly. That means:

- **No sandbox, no `bash`.** The model's only execution surface is the tools you write.
- **But prompt injection reaches whatever your tools expose.** Narrow, typed
  parameters; scope queries to the session's principal; authorize inside tools with
  your existing layer; treat tool output fed back to the model as untrusted.
- **Approvals are the guardrail.** Anything irreversible or externally visible should
  be `:once` / `:always`.
- Webhooks verify signatures in constant time; HTTP auth fails closed; dev routes never
  mount outside development.

## Known limitations

1. **SSE holds a thread per client** — fine for dev UIs and modest fleets.
   Catch-up reads are batched (`stream_catch_up_batch`), so reconnects on
   long sessions don't load the whole history in one query.
2. **Databases: SQLite and PostgreSQL are tested** (the suite runs on both).
   MySQL is untested and has known caveats: the turn claim's guarded UPDATE
   uses a self-referencing subquery (MySQL error 1093 territory) and the
   schema uses JSON column defaults — patches welcome once there's demand.
3. **At-least-once execution** — a step interrupted mid-flight re-runs on retry; tool
   side effects need idempotency or approval gates. Consumers dedupe events by
   `(session, index)`.
4. **Cancellation is cooperative** — the runner does not stream, so a cancel takes
   effect at the next step boundary (an in-flight model call finishes first). A parked
   turn cancels instantly.
5. **Sessions retire explicitly** — finishing a turn never ends the session; `reset` is
   the only terminal transition (and the only continuation-token release).
6. One agent per app (`agent/` singular).

## Development

```bash
bin/rails test                     # the whole suite — offline, deterministic fake LLM
script/demo.sh                     # the kill -9 demo, narrated
script/verify_generators.sh        # generators against a fresh rails new app
script/verify_standalone.sh        # the standalone one-process arc
script/smoke.sh                    # optional: real model (needs NVIDIA_API_KEY)
```

Tests run against a scripted fake Chat-Completions server — zero network, zero keys,
zero flake. The kill/resume arcs use real processes and real signals.

## Status: preview (0.0.x)

xeno is an early preview. It is heavily tested (176 tests on SQLite and PostgreSQL,
end-to-end kill-and-resume suites, adversarially reviewed) but has **no production
mileage yet**, and **anything may change between 0.0.x releases**. It targets RubyLLM v2
(unreleased; pinned to a known-good commit — see the warning under "Two ways in");
the first rubygems release will align with v2 GA.
`0.1.0` will mark the first release we consider stable enough to build on. See
[CHANGELOG.md](CHANGELOG.md).

MIT License.
