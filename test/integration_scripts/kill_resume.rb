# Runs inside the dummy app via `bin/rails runner` — one phase per process.
#
#   MODE=park:   opens a session whose turn executes record_alpha (recorded,
#                counter file appended) and then kill_bomb, which SIGKILLs
#                this very process mid-turn. Prints TURN_ID first.
#   MODE=resume: a genuinely fresh process claims the stale turn, fast-forwards
#                (record_alpha must NOT re-execute), executes the now-disarmed
#                kill_bomb, and finishes the turn.
#
# ENV: FAKE_LLM_URL, COUNTER_FILE, MODE, TURN_ID (resume), DISARM (resume)

require Rails.root.join("../support/test_definition").to_s

RubyLLM.configure { |c| c.ollama_api_base = ENV.fetch("FAKE_LLM_URL") }

class RecordAlpha < Xeno::Tool
  description "Records an execution to the counter file."
  parameter :note, description: "Note to record"

  def execute(note:)
    File.open(ENV.fetch("COUNTER_FILE"), "a") { |f| f.puts("executed #{note}") }
    { ok: true }
  end
end

class KillBomb < Xeno::Tool
  description "Kills the current process unless disarmed."

  def execute
    return { disarmed: true } if ENV["DISARM"] == "1"

    Process.kill("KILL", Process.pid)
    sleep 5 # never reached
  end
end

definition = TestDefinition.new(tools: { "record_alpha" => RecordAlpha, "kill_bomb" => KillBomb })

case ENV.fetch("MODE")
when "park"
  session = Xeno::Session.open!(message: "record something, then explode", definition: definition)
  turn = session.turns.order(:sequence).last
  puts "TURN_ID=#{turn.id}"
  $stdout.flush

  Xeno::TurnRunner.new(turn, definition: definition).run
  puts "UNREACHABLE — the kill bomb did not fire"
  exit 2
when "resume"
  Xeno.config.turn_stale_after = 0
  turn = Xeno::Turn.find(Integer(ENV.fetch("TURN_ID")))
  result = Xeno::TurnRunner.new(turn, definition: definition).run
  turn.reload
  final = turn.session.chat.messages_association.order(:id).last
  puts "RESULT=#{result} STATUS=#{turn.status}"
  puts "FINAL=#{final.content}"
else
  abort "unknown MODE"
end
