# frozen_string_literal: true

# The FULL runtime (Session.open! with
# the dummy app's real agent definition, TurnJob, approval gate) across two
# short-lived processes.
#
#   MODE=park:   turn 1 hits charge_card (approval :always) and PARKS; the
#                process then SIGKILLs itself — nothing survives but rows.
#   MODE=resume: a fresh process approves the action (Xeno::Inputs) and runs
#                the resume job to completion.
#
# ENV: FAKE_LLM_URL, CHARGE_LOG, MODE, TURN_ID/ACTION_ID (resume)

RubyLLM.configure { |c| c.ollama_api_base = ENV.fetch("FAKE_LLM_URL") }

case ENV.fetch("MODE")
when "park"
  session = Xeno::Session.open!(message: "Please charge $42.00 for the Pro upgrade.")
  turn = session.turns.order(:sequence).last
  Xeno::TurnJob.perform_now(turn.id)

  # session state must survive the kill (rows are the only survivor).
  session.state.update("written" => "before the kill", "count" => 1)

  turn.reload
  action = turn.actions.order(:id).last
  puts "TURN_ID=#{turn.id} ACTION_ID=#{action&.id} TURN_STATUS=#{turn.status} SESSION_STATUS=#{session.reload.status}"
  $stdout.flush

  # The park already released everything; the kill just makes it undeniable.
  Process.kill("KILL", Process.pid)
when "resume"
  turn = Xeno::Turn.find(Integer(ENV.fetch("TURN_ID")))
  action = Xeno::Action.find(Integer(ENV.fetch("ACTION_ID")))

  puts "STATE_AFTER_KILL=#{turn.session.state.get('written').inspect} STATE_COUNT=#{turn.session.state.get('count')}"

  Xeno::Inputs.approve!(action, principal: { "user" => "demo-approver" })
  Xeno::TurnJob.perform_now(turn.id)

  turn.reload
  final = turn.session.chat.messages_association.order(:id).last
  puts "RESULT_STATUS=#{turn.status} SESSION_STATUS=#{turn.session.reload.status}"
  puts "FINAL=#{final.content}"
else
  abort "unknown MODE"
end
