# Changelog

Format follows [Keep a Changelog](https://keepachangelog.com); versions follow
[SemVer](https://semver.org). **xeno is on the `0.0.x` preview line: any release may
change anything.** `0.1.0` will mark the first release we consider usable in anger:
after RubyLLM v2 GA is absorbed and the API has held still through early-adopter
feedback.

## [Unreleased]

### Changed

- The `ruby_llm` pin moved from `be80b6f1` to `9ca2c002` (45 commits of upstream
  work). Existing installs need the new migration (`bin/rails
  xeno:install:migrations` then `db:migrate`): the per-attempt usage ledger is now
  `ruby_llm_usages`, and its operation check constraint accepts the full set of
  operations the ledger records.

### Fixed

- A compaction summary row no longer carries the provider metadata of the
  assistant message it replaced. Thinking, citations, server tool calls and the
  raw provider content all reset when a row is repurposed into a summary.

## [0.0.2] - 2026-08-13

**Upgrading from 0.0.1 requires a fresh database.** The migrations were squashed
and the old stamps no longer exist, so there is no migration path forward: the
`0.0.x` preview line reserves exactly this.

### Added

- Interop with RubyLLM's tool approvals. A tool that declares `requires_approval`
  and no xeno `approval` policy parks for approval instead of executing ungated;
  an explicit policy, including `:never`, still wins. Approve and deny decisions
  also land on the standard `ruby_llm_tool_calls.approval` column, so tooling
  built against RubyLLM's convention reads xeno sessions natively.
- Tools that declare a `tool_call:` keyword on `execute` receive the
  `RubyLLM::ToolCall` they were invoked by, so a tool body can read its own
  call id for logging or correlation. Tools without the keyword are called
  exactly as before.

### Changed

- The `ruby_llm` pin moved from `2aaddf96` to `be80b6f1` (145 commits of upstream
  v2 development). No xeno API usage changed; the bundle swaps `ruby_llm-schema`
  for `schematist`. The scaffold Gemfile and README point at the new ref.
- The engine's eight migrations are now two: `create_ruby_llm_tables` and
  `create_xeno_tables`. The old set replayed pre-release history, creating tables
  only to drop them again, through a database no install has ever had. The new
  pair produces the same final schema without the churn, and each
  `ruby_llm_*` table is skipped when the database
  already has it, so a host app that ran ruby_llm's own installer keeps what it
  owns.
- The transcript tables match upstream's current install template: tool calls
  carry `approval`, messages carry `server_tool_calls` and `raw_content`. All
  three are read behind column guards, so behavior is unchanged until the pinned
  ruby_llm persists them.
- The `Gemfile` no longer prefers a local ruby_llm checkout when one happens to
  sit next door. Development bundles the same pinned ref as everyone else.

### Fixed

- Removing an agent's instructions now takes effect at the next turn, the same
  way editing them always has: staging clears the persisted system message when
  nothing resolves, instead of silently keeping the stale one.

## [0.0.1] - 2026-08-07

The first public release of xeno, a framework for durable AI agents built on Rails:

- `agent/` conventions with path-derived names (`agent.rb`, `instructions.md`,
  dynamic `instructions.rb`, `tools/`, `hooks/`, `schedules/`, `channels/`).
- Durable session → turn → step runtime on ActiveJob: atomic claims, fencing tokens,
  heartbeats (including during long calls), checkpoint replay, a reaper for orphaned
  turns, graceful-shutdown handoff, per-turn step budgets.
- Human-in-the-loop parking: tool `approval` policies, `ask_question`, crash-safe
  approve→resume, full text resolution of prompts (labels, indexes, held replies).
- Append-only event stream (SSE + NDJSON) with cursor replay; the events table doubles
  as an audit log.
- Compaction, per-session token budgets, session-scoped state, steering, pending-message
  queueing with drain-on-park.
- Channels: HTTP (fail-closed auth, per-principal session ownership) and Slack
  (signature verification, event dedup, thread sessions, text approvals, optional
  post-then-edit streaming).
- Markdown cron schedules compiled to Solid Queue recurring entries, with dedup.
- Generators (`xeno:install`, `xeno:tool`) and standalone mode: `xeno new my-agent` /
  `xeno server` for one process, sqlite, zero services. Scaffolds include a pinned
  `ruby_llm` Gemfile, dotenv, and an AGENTS.md pointing coding agents at the gem docs.
- Standalone first boot refreshes the model registry after the boot migrations, so
  current model ids resolve without a manual `RubyLLM.models.refresh!`.
- Tracks RubyLLM v2 (unreleased) at a pinned git commit: transcript support tables
  (`ruby_llm_*`), per-attempt usage ledger backing token budgets and compaction.
- Test suite: 180 runs / 987 assertions on SQLite and PostgreSQL, plus end-to-end
  kill-and-resume scripts with real processes and real signals.
