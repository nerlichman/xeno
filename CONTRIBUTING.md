# Contributing to xeno

Thanks for helping build durable agents for Ruby.

## Setup

```bash
git clone https://github.com/nerlichman/xeno && cd xeno
bundle install
bin/rails test          # the whole suite — offline, deterministic fake LLM, no keys
```

If your shell lacks a UTF-8 locale (some CI images), export
`LC_ALL=en_US.UTF-8 RUBYOPT=-Eutf-8` first.

Until RubyLLM v2 is released, the Gemfile resolves `ruby_llm` from a pinned git
commit (or a local sibling checkout when present). The pin is load-bearing; see the
comment in the Gemfile.

## Making changes

- Every behavioral change lands with a test; bug fixes include a regression test that
  fails before the fix.
- Run the narrowest relevant tests while iterating; run `bin/rails test` before opening
  a PR. Postgres portability: `DATABASE_URL=postgres://... bin/rails test`.
- The end-to-end scripts (`script/demo.sh`, `script/verify_standalone.sh`,
  `script/verify_generators.sh`) must keep passing for runtime-touching changes.
- Style is `rubocop-rails-omakase` (`bundle exec rubocop`).
- Runtime invariants live in `docs/runtime.md` — if your change alters observable
  behavior, update the docs in the same PR. Keep docs honest: never claim more than
  the code does.

## Reporting issues

Use GitHub issues with a minimal reproduction — `xeno new repro-app` gives you a clean
standalone app in seconds. Report security issues privately via
[GitHub security advisories](https://github.com/nerlichman/xeno/security/advisories/new),
not the public tracker.
