# frozen_string_literal: true

require "test_helper"
require "xeno/schedules"

# Regression: nothing owned turns that fell out of the
# retry ladder. The reaper re-enqueues work with no live owner — the
# mid-step-kill wedge (running + stale heartbeat, job dead in the queue's
# failed set) and the approve-then-crash orphan (all actions resolved, no
# resume job).
class ReaperTest < ActiveSupport::TestCase
  include ActiveJob::TestHelper

  class Gated < Xeno::Tool
    description "Needs approval."
    approval :always

    def execute
      { ok: true }
    end
  end

  def start_session(definition, message: "go")
    session = Xeno::Session.open!(message: message, definition: definition)
    [ session, session.turns.order(:sequence).last ]
  end

  def park_on_gated
    start_fake_llm do |body|
      if FakeLLM.tool_result?(body)
        FakeLLM.text("done")
      else
        FakeLLM.tool_call("gated", {}, id: "call_reaper_gate")
      end
    end
    definition = TestDefinition.new(tools: { "gated" => Gated })
    session, turn = start_session(definition)
    assert_equal :parked, Xeno::TurnRunner.new(turn, definition: definition).run
    [ session, turn.reload ]
  end

  test "mid-step-kill wedge: a stale running turn is re-enqueued and reclaimable" do
    start_fake_llm
    definition = TestDefinition.new
    _session, turn = start_session(definition)
    turn.claim!
    turn.update_columns(heartbeat_at: 1.hour.ago, updated_at: 1.hour.ago) # owner died; queue gave up

    rescued = nil
    assert_enqueued_with(job: Xeno::TurnJob, args: [ turn.id ]) do
      rescued = Xeno::Reaper.sweep!
    end
    assert_equal [ turn.id ], rescued.map(&:id)

    assert_equal :completed, Xeno::TurnRunner.new(turn.reload, definition: definition).run
  end

  test "stale pending turn (lost job) is re-enqueued" do
    start_fake_llm
    definition = TestDefinition.new
    _session, turn = start_session(definition)
    turn.update_columns(updated_at: 1.hour.ago) # staged, but the job never came

    assert_enqueued_with(job: Xeno::TurnJob, args: [ turn.id ]) do
      Xeno::Reaper.sweep!
    end
  end

  test "approve-then-crash orphan: resolved-but-waiting turn is resumed" do
    session, turn = park_on_gated
    action = turn.actions.sole

    # Simulate the crash window: the resolution landed but the resume
    # (status flip + enqueue) never happened.
    action.update!(status: "approved", resolved_at: Time.current)
    turn.update_columns(updated_at: 1.hour.ago)
    assert_equal "waiting", turn.reload.status

    rescued = nil
    assert_enqueued_with(job: Xeno::TurnJob, args: [ turn.id ]) do
      rescued = Xeno::Reaper.sweep!
    end
    assert_equal [ turn.id ], rescued.map(&:id)
    assert_equal "pending", turn.reload.status
    assert_equal "running", session.reload.status
  end

  test "genuinely parked and fresh turns are never touched" do
    _session, parked_turn = park_on_gated
    parked_turn.update_columns(updated_at: 1.hour.ago) # old, but truly waiting on a human

    definition = TestDefinition.new
    _s2, fresh_pending = start_session(definition)
    _s3, fresh_running = start_session(definition)
    fresh_running.claim!

    assert_no_enqueued_jobs(only: Xeno::TurnJob) do
      assert_empty Xeno::Reaper.sweep!
    end
    assert_equal "waiting", parked_turn.reload.status
    assert_equal "pending", fresh_pending.reload.status
    assert_equal "running", fresh_running.reload.status
  end

  test "ReaperJob performs a sweep" do
    start_fake_llm
    definition = TestDefinition.new
    _session, turn = start_session(definition)
    turn.update_columns(updated_at: 1.hour.ago)

    assert_enqueued_with(job: Xeno::TurnJob, args: [ turn.id ]) do
      Xeno::ReaperJob.perform_now
    end
  end

  test "schedules:sync writes the reaper entry into every environment, including development" do
    Dir.mktmpdir do |dir|
      path = File.join(dir, "recurring.yml")
      definition = TestDefinition.new
      def definition.schedules = {}

      result = Xeno::Schedules.sync!(definition: definition, path: path)

      assert result.key?("production")
      assert result.key?("development")
      result.each do |_env, section|
        entry = section[Xeno::Schedules::REAPER_KEY]
        assert_equal "Xeno::ReaperJob", entry["class"]
      end
    end
  end
end
