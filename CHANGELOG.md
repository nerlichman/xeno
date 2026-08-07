# Changelog

Format follows [Keep a Changelog](https://keepachangelog.com); versions follow
[SemVer](https://semver.org). **xeno is on the `0.0.x` preview line: any release may
change anything.** `0.1.0` will mark the first release we consider usable in anger —
after RubyLLM v2 GA is absorbed and the API has held still through early-adopter
feedback.

## [Unreleased]

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
  `xeno server` — one process, sqlite, zero services. Scaffolds include a pinned
  `ruby_llm` Gemfile, dotenv, and an AGENTS.md pointing coding agents at the gem docs.
- Standalone first boot refreshes the model registry after the boot migrations, so
  current model ids resolve without a manual `RubyLLM.models.refresh!`.
- Tracks RubyLLM v2 (unreleased) at a pinned git commit: transcript support tables
  (`ruby_llm_*`), per-attempt usage ledger backing token budgets and compaction.
- Test suite: 180 runs / 987 assertions on SQLite and PostgreSQL, plus end-to-end
  kill-and-resume scripts with real processes and real signals.
