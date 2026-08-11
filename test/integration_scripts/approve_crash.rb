# frozen_string_literal: true

# The kill window, made real: a queue backend whose enqueue happens
# AFTER the resolution transaction commits (ActiveJob's deferred
# enqueue_after_transaction_commit mode), with the process dying between
# the commit and the enqueue. The committed state is the orphan the reaper
# must recover: action approved, turn pending, no job anywhere.
#
# ENV: ACTION_ID

action = Xeno::Action.find(Integer(ENV.fetch("ACTION_ID")))

# Simulate the deferred-enqueue backend...
Xeno::TurnJob.enqueue_after_transaction_commit = true
# ...and die exactly between the commit and the enqueue.
adapter = Xeno::TurnJob.queue_adapter
def adapter.enqueue(_job)
  Process.kill("KILL", Process.pid)
end

Xeno::Inputs.approve!(action, principal: { "user" => "crash-approver" })
puts "UNREACHABLE: the kill must land before the enqueue returns"
