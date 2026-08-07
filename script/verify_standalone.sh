#!/bin/bash
# Standalone-mode verification: scaffold with `xeno new`, run web + Solid
# Queue in ONE puma process, drive the whole durability arc over HTTP —
# park on an approval, kill -9 the process (web AND queue die together),
# restart, approve, resume. Assertions via curl + sqlite3.
#
# Usage: script/verify_standalone.sh [workdir]
set -euo pipefail

export LC_ALL="${LC_ALL:-en_US.UTF-8}"
export RUBYOPT="-Eutf-8"

XENO_PATH="$(cd "$(dirname "$0")/.." && pwd)"
RUBY_LLM_PATH="$(cd "$XENO_PATH/../ruby_llm-original" && pwd)"
WORKDIR="${1:-$(mktemp -d)}"
PORT=3413
FAKE_PORT=4667
BASE="http://127.0.0.1:$PORT"

export FAKE_LLM_PORT="$FAKE_PORT"
export FAKE_LLM_URL="http://127.0.0.1:$FAKE_PORT"
# Deterministic run: no first-boot registry refresh against real providers.
export XENO_SKIP_MODEL_REFRESH=1
CHARGE_LOG="$WORKDIR/charges.txt"
export CHARGE_LOG

PIDS=()
cleanup() {
  for pid in "${PIDS[@]:-}"; do kill -9 "$pid" 2>/dev/null || true; done
}
trap cleanup EXIT

say() { printf "\n\033[1;35m▶ %s\033[0m\n" "$*"; }
db() { sqlite3 "$WORKDIR/demo_agent/storage/xeno_development.sqlite3" "$1"; }

# A zombie from an aborted run would collide on the port.
lsof -ti ":$PORT" 2>/dev/null | xargs kill -9 2>/dev/null || true
lsof -ti ":$FAKE_PORT" 2>/dev/null | xargs kill -9 2>/dev/null || true

mkdir -p "$WORKDIR" && cd "$WORKDIR"
rm -rf demo_agent

say "xeno new demo_agent (the four-file scaffold)"
ruby "$XENO_PATH/exe/xeno" new demo_agent
cd demo_agent
ls -A

# Local checkouts for both gems — no network during verification.
ruby -e 'g = File.read("Gemfile"); File.write("Gemfile", g.sub(%(gem "xeno"), %(gem "xeno", path: "'"$XENO_PATH"'")))'
ruby -e 'g = File.read("Gemfile"); File.write("Gemfile", g.sub(/^gem "ruby_llm".*$/, %(gem "ruby_llm", path: "'"$RUBY_LLM_PATH"'")))'

say "bundle install"
bundle install --quiet

# The demo tool (gated) and a fake-model agent config.
cat > agent/tools/charge_card.rb <<'TOOL'
class Xeno::Tools::ChargeCard < Xeno::Tool
  description "Charge the customer's card. Irreversible."
  parameter :amount_cents, type: :integer, description: "Amount in cents"
  approval :always

  def execute(amount_cents:)
    File.open(ENV.fetch("CHARGE_LOG"), "a") { |f| f.puts("charged #{amount_cents}") }
    { status: "succeeded", charge_id: "ch_#{amount_cents}" }
  end
end
TOOL

cat > agent/agent.rb <<'AGENT'
RubyLLM.configure { |c| c.ollama_api_base = ENV["FAKE_LLM_URL"] } if ENV["FAKE_LLM_URL"]

Xeno.agent do
  model "fake-model", provider: :ollama, assume_model_exists: true
end
AGENT

say "starting the fake model + ONE puma process (web + Solid Queue inside)"
ruby "$XENO_PATH/script/demo_fake_llm.rb" >/tmp/xeno_standalone_fake.log 2>&1 &
PIDS+=($!)

start_server() {
  # After a kill -9 the forked Solid Queue processes (which inherited puma's
  # listen socket) hold the port for ~a second until they notice puma is
  # gone — wait for the port to free instead of racing an EADDRINUSE.
  for _ in $(seq 1 150); do
    lsof -ti ":$PORT" >/dev/null 2>&1 || break
    sleep 0.2
  done
  SOLID_QUEUE_IN_PUMA=1 PORT=$PORT bundle exec puma -C "$XENO_PATH/lib/xeno/standalone/puma.rb" config.ru \
    >>/tmp/xeno_standalone_server.log 2>&1 &
  SERVER=$!
  PIDS+=($SERVER)
  until curl -sf "$BASE/agent/v1/health" >/dev/null; do sleep 0.3; done
}
start_server
echo "one process: puma $SERVER (queue included)"

say "1) message over HTTP (dev default auth)"
CREATE=$(curl -s -X POST "$BASE/agent/v1/sessions" -H "Content-Type: application/json" \
  -d '{"message": "Charge $42 for my upgrade."}')
echo "$CREATE" | head -c 400
SESSION_ID=$(ruby -rjson -e 'puts JSON.parse(ARGV[0])["session_id"]' "$CREATE")
[ -n "$SESSION_ID" ] && [ "$SESSION_ID" != "null" ] || { echo "FAIL: no session id"; exit 1; }

say "2) the in-process queue runs the turn and parks on the approval"
until [ "$(db "SELECT status FROM xeno_sessions WHERE id = $SESSION_ID")" = "waiting" ]; do sleep 0.4; done
echo "session: waiting; charge log: $( [ -f "$CHARGE_LOG" ] && cat "$CHARGE_LOG" || echo '(empty)')"

say "3) kill -9 the WHOLE app (web and queue die together)"
kill -9 "$SERVER"
echo "process $SERVER gone"

say "4) restart, approve over HTTP"
start_server
ACTION_ID=$(db "SELECT a.id FROM xeno_actions a JOIN xeno_turns t ON t.id = a.turn_id WHERE t.session_id = $SESSION_ID AND a.status = 'pending_approval'")
curl -s -X POST "$BASE/agent/v1/sessions/$SESSION_ID/inputs" -H "Content-Type: application/json" \
  -d "{\"action_id\": $ACTION_ID, \"decision\": \"approve\"}"
echo

say "5) resume completes; the stream shows the story"
until [ "$(db "SELECT status FROM xeno_turns WHERE session_id = $SESSION_ID")" = "completed" ]; do sleep 0.4; done
curl -sN --max-time 2 "$BASE/agent/v1/sessions/$SESSION_ID/stream?start_index=0" | grep "^event: " || true

FINAL=$(db "SELECT content FROM xeno_messages WHERE chat_id = (SELECT chat_id FROM xeno_sessions WHERE id = $SESSION_ID) ORDER BY id DESC LIMIT 1")
echo "final answer: $FINAL"
echo "charge log: $(cat "$CHARGE_LOG")"

[ "$FINAL" = "Done! I charged \$42.00 — receipt ch_4200." ] || { echo "FAIL: unexpected final answer"; exit 1; }
[ "$(wc -l < "$CHARGE_LOG" | tr -d ' ')" = "1" ] || { echo "FAIL: tool ran more than once"; exit 1; }

say "STANDALONE VERIFICATION PASS (workdir: $WORKDIR)"
