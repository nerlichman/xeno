# xeno

xeno is a framework for durable AI agents. Built on Rails, it runs standalone (`xeno new my-agent`) or inside the Rails app you already have.

A xeno agent is a session that survives restarts and deploys mid-turn, waits days for a human approval without holding a process, and resumes exactly where it stopped. Under the hood, xeno composes [RubyLLM](https://rubyllm.com) for model calls with ActiveJob and ActiveRecord for durability.

> [!WARNING]
> xeno currently tracks RubyLLM v2 (unreleased), pinned to git ref [`be80b6f1`](https://github.com/crmne/ruby_llm/commit/be80b6f1). The released `ruby_llm` gem (1.16.0) is not compatible. Standalone apps get the pin from the scaffold's Gemfile. If your Rails app already uses a released `ruby_llm`, xeno cannot run alongside it today. This resolves at RubyLLM v2 GA, when xeno switches to the released gem.

## The filesystem is the authoring interface

A xeno agent is a directory:

```text
agent/
├── agent.rb            # optional: model and runtime config
├── instructions.md     # the always-on system prompt
├── instructions.rb     # optional: dynamic instructions, resolved per turn
├── tools/
│   └── get_weather.rb  # tool "get_weather" (class Xeno::Tools::GetWeather)
├── hooks/
│   └── metrics.rb      # observe-only event handlers
└── schedules/
    └── weekly_recap.md # cron-triggered agent session
```

The path supplies the name; there are no `name:` fields. `xeno info` prints the resolved agent and flags anything misplaced.

## Quick start

Standalone, from nothing:

```bash
xeno new my-agent && cd my-agent
bundle install
xeno server
```

One process: web and jobs in the same Puma, SQLite, no external services. The dev chat UI is at `http://localhost:3000/agent/dev`.

In an existing Rails app:

```bash
bundle add xeno
bin/rails g xeno:install
bin/rails db:migrate
```

The generator creates `agent/` at your app root and mounts the engine at `/agent`. Tools are your domain code: they call your models, policies, and credentials directly, with no connector layer in between.

## A minimal example

Add a gated tool at `agent/tools/charge_card.rb`:

```ruby
class Xeno::Tools::ChargeCard < Xeno::Tool
  description "Charge the customer's card. Irreversible."
  parameter :amount_cents, type: :integer, description: "Amount in cents"

  approval :always

  def execute(amount_cents:)
    PaymentService.charge!(amount_cents)
  end
end
```

Send "charge $42 to my card" and the agent decides to call the tool. `approval :always` parks the turn: the job ends, and the pending approval is a database row. Kill the process, deploy, come back tomorrow. When you approve (over HTTP, or one click in the dev UI), the turn resumes from its last checkpoint and the tool runs exactly once.

That arc is the flagship integration test (`test/demo_acceptance_test.rb`, three real processes) and a watchable script (`script/demo.sh`).

## How durability works

Work nests session → turn → step. A turn is one ActiveJob; a step is one model call plus its tool calls, checkpointed in your database:

- A tool execution and its transcript write commit in one transaction, so recorded calls never re-execute. A killed process resumes from the last checkpoint.
- Turn claims use an atomic compare-and-swap with heartbeats, stale-claim takeover, fencing tokens, and a reaper for orphaned turns. Any ActiveJob backend works; with Solid Queue the whole story is database rows.
- Parking ends the job. A parked session costs nothing for days; resolving its pending input enqueues the resume.
- Messages that arrive mid-turn queue up and fold into the next turn.

`docs/runtime.md`, shipped inside the gem, documents the runtime invariants in full.

## Sessions over HTTP

The engine mounts at `/agent`:

```text
POST /agent/v1/sessions                    create a session          → { session_id, continuation_token }
POST /agent/v1/sessions/:id/messages       follow-up message         (steer: true replaces the active turn)
POST /agent/v1/sessions/:id/inputs         approve / deny / answer   (by action_id)
POST /agent/v1/sessions/:id/cancel         stop the active turn
POST /agent/v1/sessions/:id/compact        summarize old history
POST /agent/v1/sessions/:id/reset          retire the session
GET  /agent/v1/sessions/:id/stream         event stream
GET  /agent/v1/health
```

Events are append-only rows with a per-session index. The stream endpoint serves Server-Sent Events (SSE) or NDJSON (`?format=ndjson`) and replays from any cursor (`?start_index=N`); the same table is your audit log.

## Slack

Two credentials and the agent answers mentions in threads:

```ruby
# agent/channels/slack.rb
Xeno.channel :slack do
  signing_secret ENV["SLACK_SIGNING_SECRET"]
  bot_token     ENV["SLACK_BOT_TOKEN"]
end
```

Standalone apps load these from `.env`; in a Rails app, `Rails.application.credentials` works here too.

Point your Slack app's Events API at `POST /agent/v1/channels/slack/events`. xeno verifies signatures in constant time, answers the URL handshake, dedupes retries, and acks inside Slack's 3-second window. Mentions and direct messages start sessions; each thread is one session; replies continue it.

When the agent parks, the prompt lands in the thread, and replies resolve it:

- **approve** or **deny** settles an approval
- a number ("2") or a label ("tuesday") picks a choice
- any text answers a free-form question
- unrelated replies are held as the next message, never treated as an answer

Replies post at turn completion by default; `stream_replies true` in the channel block opts into post-then-edit streaming.

## Schedules

A schedule is a markdown file with a cron line:

```markdown
---
cron: "0 9 * * 1"
---
Summarize the week's activity and post highlights to the team.
```

`bin/rails xeno:schedules:sync` compiles `agent/schedules/*.md` into Solid Queue recurring entries; standalone apps sync at boot. Development never fires on cadence: trigger by name via the dev endpoint. Schedule runs execute under the app principal and cannot wait on a human, so a gated tool deterministically fails the run.

## Configuration

Standalone apps configure in `agent/agent.rb`; mounted apps use `config/initializers/xeno.rb`:

```ruby
Xeno.configure do |config|
  # Fail closed: every endpoint except health returns 401 until you set this.
  # The truthy return value becomes the session principal.
  config.authenticate = ->(request) do
    token = request.headers["Authorization"]&.delete_prefix("Bearer ")
    { "user" => "api" } if ActiveSupport::SecurityUtils.secure_compare(
      token.to_s, ENV["XENO_API_KEY"].to_s
    )
  end

  config.max_steps = 20               # per-turn model-call budget
  config.turn_stale_after = 5.minutes # dead-worker takeover window
end
```

Every knob is listed in [docs/configuration.md](docs/configuration.md).

Development with no lambda configured stays usable on localhost; everywhere else the absence of a checker is a 401.

The principal is also the ownership boundary: a session belongs to the principal stamped at creation, and every session-scoped endpoint returns 404 for any other principal. See `docs/runtime.md` for the authorization rules.

### Model registry

Model ids resolve against RubyLLM's registry, and models released after the gem's catalog snapshot need a registry refresh before they resolve. Standalone apps refresh automatically on first boot, right after the boot-time migrations (skip with `XENO_SKIP_MODEL_REFRESH=1`). To refresh later, run it manually for now (a friendlier command is planned):

```bash
# mounted
bin/rails runner "RubyLLM.models.refresh!"
```

```bash
# standalone
bundle exec ruby -r dotenv/load -r xeno/standalone -e 'Xeno.rails_app; Xeno.definition; RubyLLM.models.refresh!'
```

Or bypass the registry per model with `model "the-id", provider: :openai, assume_model_exists: true`. Automatic compaction then needs `config.compaction_context_window`, since the registry cannot supply the window.

## Security model

xeno runs tools inside your app on purpose:

- There is no sandbox and no `bash` tool. The model's only execution surface is the tools you write.
- That power cuts both ways: prompt injection reaches whatever your tools expose. Keep parameters narrow and typed, scope queries to the session's principal, authorize inside tools with your existing layer, and treat tool output fed back to the model as untrusted.
- Approvals are the guardrail. Gate anything irreversible or externally visible with `:once` or `:always`.
- Webhooks verify signatures in constant time, HTTP auth fails closed, and dev routes never mount outside development.

## Known limitations

- SSE holds a thread per client, which is fine for dev UIs and small deployments. Catch-up reads are batched so reconnects on long sessions stay bounded.
- SQLite and PostgreSQL are the tested databases; the suite runs on both. MySQL is untested and has known caveats.
- Execution is at-least-once: a step interrupted mid-flight re-runs on retry, so tool side effects need idempotency or approval gates. Consumers dedupe events by `(session, index)`.
- Cancellation is cooperative and lands at the next step boundary; an in-flight model call finishes first. A parked turn cancels instantly.
- Sessions retire explicitly: `reset` is the only terminal transition.
- One agent per app.

## Development

```bash
bin/rails test                     # the whole suite: offline, deterministic fake LLM
script/demo.sh                     # the kill -9 demo, narrated
script/verify_generators.sh        # generators against a fresh rails new app
script/verify_standalone.sh        # the standalone one-process arc
```

Tests run against a scripted fake server: no network, no keys, no flake. The kill-and-resume arcs use real processes and real signals.

## Status: preview (0.0.x)

xeno is an early preview with no production mileage yet; anything may change between 0.0.x releases. It targets RubyLLM v2 (unreleased, pinned to a known-good commit; see the warning above); the pin drops at v2 GA. `0.1.0` will mark the first release we consider stable enough to build on. See [CHANGELOG.md](CHANGELOG.md).

MIT License.
