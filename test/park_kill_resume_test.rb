require "test_helper"
require "open3"

# M4's definition of done: park → REAL process kill → fresh process resume →
# completion, through the full runtime (Session.open! + TurnJob + the dummy
# app's real agent/ directory with its approval-gated charge_card tool).
# Spike #1, elevated to an integration test.
class ParkKillResumeTest < ActiveSupport::TestCase
  self.use_transactional_tests = false

  DUMMY_ROOT = File.expand_path("dummy", __dir__)
  SCRIPT = File.expand_path("integration_scripts/park_kill_resume.rb", __dir__)

  def run_script(env)
    Open3.capture2e(
      {
        "RAILS_ENV" => "test",
        "LC_ALL" => "en_US.UTF-8",
        "RUBYOPT" => "-Eutf-8"
      }.merge(env),
      "bin/rails", "runner", SCRIPT,
      chdir: DUMMY_ROOT
    )
  end

  test "park -> kill -9 -> fresh process approves and resumes to completion" do
    fake = start_fake_llm do |body|
      if FakeLLM.tool_result?(body)
        result = JSON.parse(body["messages"].find { |m| m["role"] == "tool" }["content"])
        FakeLLM.text("Done — charged (#{result['charge_id']}).")
      else
        FakeLLM.tool_call("charge_card", { amount_cents: 4200 }, id: "call_m4_charge")
      end
    end

    turn_id = nil
    Dir.mktmpdir do |dir|
      charge_log = File.join(dir, "charges.txt")
      base_env = { "FAKE_LLM_URL" => fake.url, "CHARGE_LOG" => charge_log }

      # --- phase 1: park, then die by SIGKILL ---
      out1, status1 = run_script(base_env.merge("MODE" => "park"))
      refute status1.success?
      assert_equal 9, status1.termsig, "park process must die by signal 9 (output: #{out1})"

      turn_id = out1[/TURN_ID=(\d+)/, 1]
      action_id = out1[/ACTION_ID=(\d+)/, 1]
      assert turn_id && action_id, "park phase must print ids (output: #{out1})"
      assert_includes out1, "TURN_STATUS=waiting"
      assert_includes out1, "SESSION_STATUS=waiting"
      refute File.exist?(charge_log), "gated tool must not run before approval"

      # Nothing but rows survives the kill.
      turn = Xeno::Turn.find(turn_id.to_i)
      assert_equal "waiting", turn.status
      assert_equal "pending_approval", Xeno::Action.find(action_id.to_i).status
      assert_equal %w[input.requested session.waiting],
        turn.session.events.order(:index).last(2).map(&:event_type)

      # --- phase 2: fresh process approves and resumes ---
      out2, status2 = run_script(
        base_env.merge("MODE" => "resume", "TURN_ID" => turn_id, "ACTION_ID" => action_id)
      )
      assert status2.success?, "resume failed: #{out2}"
      assert_includes out2, %(STATE_AFTER_KILL="before the kill" STATE_COUNT=1),
        "session state survives kill -9 into the fresh process"
      assert_includes out2, "RESULT_STATUS=completed"
      assert_includes out2, "SESSION_STATUS=running"
      assert_includes out2, "FINAL=Done — charged (ch_4200)."

      assert_equal [ "charged 4200" ], File.readlines(charge_log).map(&:strip),
        "approved tool must run exactly once"

      turn.reload
      assert_equal "completed", turn.status
      action = Xeno::Action.find(action_id.to_i)
      assert_equal "completed", action.status
      assert_equal({ "user" => "demo-approver" }, action.resolved_by)

      # The event stream tells the whole story, in order.
      types = turn.session.events.order(:index).pluck(:event_type)
      expected_arc = %w[session.started message.received turn.started step.started
                        step.completed actions.requested input.requested session.waiting
                        action.result step.started step.completed message.completed turn.completed]
      assert_equal expected_arc, types
    ensure
      if turn_id
        session = Xeno::Turn.find_by(id: turn_id.to_i)&.session
        chat = session&.chat
        session&.destroy
        chat&.destroy
      end
    end
  end
end
