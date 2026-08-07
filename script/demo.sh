#!/bin/bash
# The human demo — the README arc, live:
#
#   message over HTTP → the agent parks on an approval → kill -9 the worker
#   → restart it → approve → the turn resumes exactly where it stopped →
#   the event stream shows the whole story.
#
# Runs against the dummy app with a deterministic fake model (no keys, no
# network). Automated twin: test/demo_acceptance_test.rb.
set -euo pipefail

export LC_ALL="${LC_ALL:-en_US.UTF-8}"
export RUBYOPT="-Eutf-8"

XENO_PATH="$(cd "$(dirname "$0")/.." && pwd)"
DUMMY="$XENO_PATH/test/dummy"
PORT=3412
FAKE_PORT=4666
KEY="demo-key-123"
CHARGE_LOG="$(mktemp -d)/charges.txt"

export RAILS_ENV=development
export XENO_SOLID_QUEUE=1
export XENO_DEMO_KEY="$KEY"
export FAKE_LLM_URL="http://127.0.0.1:$FAKE_PORT"
export FAKE_LLM_PORT="$FAKE_PORT"
export CHARGE_LOG

PIDS=()
cleanup() {
  for pid in "${PIDS[@]:-}"; do kill -9 -- "-$pid" 2>/dev/null || kill -9 "$pid" 2>/dev/null || true; done
}
trap cleanup EXIT

say() { printf "\n\033[1;36m▶ %s\033[0m\n" "$*"; }

cd "$DUMMY"

say "Fresh stage: dev database + Solid Queue tables"
rm -f storage/development.sqlite3*
bin/rails db:prepare >/dev/null
bin/rails runner 'load Rails.root.join("db/queue_schema.rb")' >/dev/null

say "Starting the fake model (deterministic, offline)"
ruby "$XENO_PATH/script/demo_fake_llm.rb" >/tmp/xeno_demo_fake.log 2>&1 &
PIDS+=($!)
sleep 1

say "Starting the app server on :$PORT and ONE Solid Queue worker"
set -m
bin/rails server -p "$PORT" >/tmp/xeno_demo_server.log 2>&1 &
PIDS+=($!)
bin/rails solid_queue:start >/tmp/xeno_demo_worker1.log 2>&1 &
WORKER=$!
PIDS+=($WORKER)
set +m

until curl -sf "http://127.0.0.1:$PORT/agent/v1/health" >/dev/null; do sleep 0.3; done

say "1) Send a message over HTTP"
CREATE=$(curl -s -X POST "http://127.0.0.1:$PORT/agent/v1/sessions" \
  -H "Authorization: Bearer $KEY" -H "Content-Type: application/json" \
  -d '{"message": "Charge $42 for my upgrade."}')
echo "$CREATE"
SESSION_ID=$(ruby -rjson -e 'puts JSON.parse(ARGV[0])["session_id"]' "$CREATE")

say "2) The worker runs the turn and PARKS on charge_card (approval :always)"
until [ "$(bin/rails runner "print Xeno::Session.find($SESSION_ID).status" 2>/dev/null)" = "waiting" ]; do sleep 0.5; done
echo "session status: waiting — zero compute held, only rows"
[ ! -f "$CHARGE_LOG" ] && echo "charge log: (empty — nothing executed)"

say "3) kill -9 the worker. Durability is not a claim, watch:"
kill -9 -- "-$WORKER" 2>/dev/null || kill -9 "$WORKER"
echo "worker $WORKER is gone"

ACTION_ID=$(bin/rails runner "print Xeno::Action.where(status: 'pending_approval').joins(:turn).where(xeno_turns: { session_id: $SESSION_ID }).first.id")
echo "the pending approval survived: action #$ACTION_ID"

say "4) Start a FRESH worker and approve over HTTP"
set -m
bin/rails solid_queue:start >/tmp/xeno_demo_worker2.log 2>&1 &
PIDS+=($!)
set +m
sleep 2
curl -s -X POST "http://127.0.0.1:$PORT/agent/v1/sessions/$SESSION_ID/inputs" \
  -H "Authorization: Bearer $KEY" -H "Content-Type: application/json" \
  -d "{\"action_id\": $ACTION_ID, \"decision\": \"approve\"}"
echo

say "5) The turn resumes exactly where it stopped — the stream tells the story"
until [ "$(bin/rails runner "print Xeno::Session.find($SESSION_ID).turns.first.status")" = "completed" ]; do sleep 0.5; done
curl -sN --max-time 2 "http://127.0.0.1:$PORT/agent/v1/sessions/$SESSION_ID/stream?start_index=0" \
  -H "Authorization: Bearer $KEY" | grep "^event: " || true

say "Final answer + proof the tool ran exactly once, in the SECOND worker"
bin/rails runner "puts Xeno::Session.find($SESSION_ID).chat.messages_association.order(:id).last.content"
echo "charge log: $(cat "$CHARGE_LOG")"

say "DEMO COMPLETE"
