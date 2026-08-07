#!/bin/bash
# M7 verification: generate a throwaway Rails app, install xeno through the
# real generators, migrate, boot, and drive the demo flow (message → tool
# call → final answer) against the fake LLM. Prints PASS at the end.
#
# Usage: script/verify_generators.sh [workdir]
set -euo pipefail

export LC_ALL="${LC_ALL:-en_US.UTF-8}"
export RUBYOPT="-Eutf-8"

XENO_PATH="$(cd "$(dirname "$0")/.." && pwd)"
RUBY_LLM_PATH="$(cd "$XENO_PATH/../ruby_llm-original" && pwd)"
WORKDIR="${1:-$(mktemp -d)}"

echo "=== workdir: $WORKDIR"
cd "$WORKDIR"
rm -rf demo_app

echo "=== rails new demo_app"
rails _8.1.3.1_ new demo_app --skip-git --skip-bundle --skip-docker --skip-ci --skip-kamal --skip-solid --quiet

cd demo_app

cat >> Gemfile <<GEMS

gem "xeno", path: "$XENO_PATH"
gem "ruby_llm", path: "$RUBY_LLM_PATH"
gem "webrick" # the verification driver's fake LLM server
GEMS

echo "=== bundle install"
bundle install --quiet

echo "=== rails g xeno:install"
bin/rails g xeno:install

echo "=== rails g xeno:tool GetWeather"
bin/rails g xeno:tool GetWeather

echo "=== db:prepare"
bin/rails db:prepare

# Point the agent at the fake model for the drive.
cat > agent/agent.rb <<'AGENT'
Xeno.agent do
  model "fake-model", provider: :ollama, assume_model_exists: true
end
AGENT

echo "=== xeno:info"
bin/rails xeno:info

echo "=== drive the demo flow"
XENO_TEST_SUPPORT="$XENO_PATH/test/support" bin/rails runner - <<'DRIVER'
require File.join(ENV.fetch("XENO_TEST_SUPPORT"), "fake_llm")

fake = FakeLLM.new do |body|
  if FakeLLM.tool_result?(body)
    FakeLLM.text("It's sunny in Rome.")
  else
    FakeLLM.tool_call("get_weather", { input: "Rome" }, id: "call_demo_weather")
  end
end.start
RubyLLM.configure { |c| c.ollama_api_base = fake.url }

session = Xeno::Session.open!(message: "What's the weather in Rome?")
turn = session.turns.order(:sequence).last
Xeno::TurnJob.perform_now(turn.id)

turn.reload
raise "turn not completed: #{turn.status} #{turn.error.inspect}" unless turn.status == "completed"

action = turn.actions.first
raise "tool action missing/failed: #{action&.status}" unless action&.status == "completed"

final = session.chat.messages_association.order(:id).last.content
raise "unexpected final answer: #{final.inspect}" unless final == "It's sunny in Rome."

events = session.events.order(:index).pluck(:event_type)
%w[session.started message.received turn.started actions.requested action.result message.completed turn.completed].each do |t|
  raise "missing event #{t} in #{events.inspect}" unless events.include?(t)
end

fake.stop
puts "GENERATORS DEMO PASS — final answer: #{final}"
DRIVER

echo "=== ALL GREEN (workdir kept at $WORKDIR)"
