# frozen_string_literal: true

require "test_helper"

# at-least-once cron redelivery must not double-run a schedule. Each
# enqueue's job_id claims a dedup row in the same transaction that opens the
# session; a redelivered job re-drives the RECORDED turn (claim CAS makes
# that a no-op when the first delivery finished) instead of opening a second
# session.
class ScheduleDedupTest < ActiveSupport::TestCase
  include ActiveJob::TestHelper

  setup do
    start_fake_llm { |_body| FakeLLM.text("weekly recap done") }
  end

  test "a redelivered tick runs the schedule exactly once" do
    job = Xeno::ScheduleJob.new("weekly_recap")

    assert_difference "Xeno::Session.count", 1 do
      job.perform_now
      job.perform_now # the queue redelivers the same job (same job_id)
    end

    session = Xeno::Session.where(channel: "schedule").order(:id).last
    assert_equal 1, session.turns.count
    assert_equal "completed", session.turns.sole.status
    assert_equal 1, Xeno::Dedup.where(scope: "schedule_run", key: job.job_id).count
  end

  test "a redelivery after a crash mid-run picks up the recorded turn instead of double-opening" do
    job = Xeno::ScheduleJob.new("weekly_recap")

    # First delivery: the session opens and commits, then the process dies
    # before the turn runs.
    boom = true
    Xeno::TurnJob.define_singleton_method(:perform_now) do |*args|
      raise IOError, "crashed mid-run" if boom

      super(*args)
    end
    begin
      assert_raises(IOError) { job.perform_now }
      boom = false

      session = Xeno::Session.where(channel: "schedule").order(:id).last
      assert_equal "pending", session.turns.sole.status, "the turn survived the crash, unowned"

      # Redelivery: no second session; the recorded turn runs to completion.
      assert_no_difference "Xeno::Session.count" do
        job.perform_now
      end
      assert_equal "completed", session.turns.sole.reload.status
    ensure
      Xeno::TurnJob.singleton_class.remove_method(:perform_now)
    end
  end

  test "two distinct ticks are two runs (dedup is per enqueue, not per schedule)" do
    assert_difference "Xeno::Session.count", 2 do
      Xeno::ScheduleJob.new("weekly_recap").perform_now
      Xeno::ScheduleJob.new("weekly_recap").perform_now
    end
  end
end
