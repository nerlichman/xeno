source "https://rubygems.org"

# Specify your gem's dependencies in xeno.gemspec.
gemspec

# The ref pin is load-bearing: upstream main and the released 1.16.0 gem are
# both incompatible with xeno. Remove the pin at RubyLLM v2 GA.
ruby_llm_clone = File.expand_path("../ruby_llm-original", __dir__)
if File.directory?(ruby_llm_clone)
  gem "ruby_llm", path: ruby_llm_clone
else
  gem "ruby_llm", github: "crmne/ruby_llm", ref: "2aaddf96"
end

gem "puma"

gem "sqlite3"

# Postgres portability run: DATABASE_URL=postgres://... bin/rails test
# (the H3 savepoint semantics only bite on PG; see test/append_savepoint_test.rb).
gem "pg"

gem "propshaft"

# Dummy-app ActiveJob backend where a real queue is needed.
gem "solid_queue"

# Fake Chat-Completions server used by the deterministic test harness.
gem "webrick"

# Omakase Ruby styling [https://github.com/rails/rubocop-rails-omakase/]
gem "rubocop-rails-omakase", require: false
