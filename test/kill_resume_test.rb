# frozen_string_literal: true

require "test_helper"
require "open3"

# THE durability proof for M3: a real `kill -9` mid-turn (the process
# SIGKILLs itself between tool executions), then a genuinely fresh process
# that claims the stale turn, fast-forwards through the recorded tool call
# without re-executing it, and completes the turn. The fake LLM lives in
# THIS process and serves both short-lived workers.
class KillResumeTest < ActiveSupport::TestCase
  self.use_transactional_tests = false

  DUMMY_ROOT = File.expand_path("dummy", __dir__)
  SCRIPT = File.expand_path("integration_scripts/kill_resume.rb", __dir__)

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

  test "kill -9 mid-turn: fresh process resumes, recorded tool never re-executes" do
    fake = start_fake_llm do |body|
      if FakeLLM.tool_result_count(body) >= 2
        FakeLLM.text("survived the crash")
      else
        FakeLLM.tool_call(
          [ [ "record_alpha", { note: "alpha" }, "call_kr_record" ],
            [ "kill_bomb", {}, "call_kr_bomb" ] ]
        )
      end
    end

    Dir.mktmpdir do |dir|
      counter_file = File.join(dir, "counter.txt")
      base_env = { "FAKE_LLM_URL" => fake.url, "COUNTER_FILE" => counter_file }

      # --- phase 1: the worker kills itself mid-turn ---
      out1, status1 = run_script(base_env.merge("MODE" => "park"))
      turn_id = out1[/TURN_ID=(\d+)/, 1]

      assert turn_id, "park phase must print the turn id (output: #{out1})"
      refute status1.success?, "the park process must die by SIGKILL"
      assert_equal 9, status1.termsig, "expected death by signal 9, got: #{status1.inspect}"
      refute_includes out1, "UNREACHABLE"

      turn = Xeno::Turn.find(turn_id.to_i)
      assert_equal "running", turn.status, "the dead worker left the turn mid-claim"
      assert_equal [ "executed alpha" ], File.readlines(counter_file).map(&:strip)

      # --- phase 2: a fresh process resumes ---
      out2, status2 = run_script(
        base_env.merge("MODE" => "resume", "TURN_ID" => turn_id, "DISARM" => "1")
      )

      assert status2.success?, "resume phase failed: #{out2}"
      assert_includes out2, "RESULT=completed STATUS=completed"
      assert_includes out2, "FINAL=survived the crash"

      assert_equal [ "executed alpha" ], File.readlines(counter_file).map(&:strip),
        "recorded tool call re-executed on resume — replay is broken"

      turn.reload
      assert_equal "completed", turn.status
      statuses = turn.actions.order(:id).pluck(:tool_name, :status)
      assert_equal [ [ "record_alpha", "completed" ], [ "kill_bomb", "completed" ] ], statuses

      roles = turn.session.chat.messages_association.order(:id).pluck(:role)
      assert_equal %w[system user assistant tool tool assistant], roles
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
