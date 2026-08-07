require "test_helper"
require "open3"

# M1(b): approve→resume is crash-safe.
#
# 1. The atomic path (regression, failed pre-fix): resolution + status flip +
#    enqueue commit in ONE transaction — a failed enqueue rolls the whole
#    resolution back, so the input is still pending and the human retries.
# 2. The kill test (scope-mandated backstop proof): a backend that enqueues
#    after commit, killed between commit and enqueue, leaves the orphan
#    (approved action + pending turn + no job) — the reaper recovers it.
class ApproveCrashTest < ActiveSupport::TestCase
  include ActiveJob::TestHelper
  self.use_transactional_tests = false

  DUMMY_ROOT = File.expand_path("dummy", __dir__)
  SCRIPT = File.expand_path("integration_scripts/approve_crash.rb", __dir__)

  setup do
    @sessions = []
  end

  teardown do
    ENV.delete("CHARGE_LOG")
    # Destroy through FRESH records: a long-lived chat's cached messages
    # association misses rows added later in the run, and dependent
    # destroy would then delete tool_calls out from under live results.
    @sessions.each do |session|
      fresh = Xeno::Session.find_by(id: session.id) || next
      chat = fresh.chat
      fresh.destroy
      chat.destroy
    end
  end

  # Park the dummy agent's real charge_card approval in this process.
  def park_charge(charge_log)
    ENV["CHARGE_LOG"] = charge_log
    start_fake_llm do |body|
      if FakeLLM.tool_result?(body)
        FakeLLM.text("Charged.")
      else
        FakeLLM.tool_call("charge_card", { amount_cents: 4200 }, id: "call_crash_#{SecureRandom.hex(4)}")
      end
    end
    session = Xeno::Session.open!(message: "Charge $42.")
    @sessions << session
    turn = session.turns.order(:sequence).last
    assert_equal :parked, Xeno::TurnRunner.new(turn).run
    [ session, turn.reload, turn.actions.sole ]
  end

  test "a failed resume enqueue rolls the whole resolution back — the input stays pending and a retry works" do
    Dir.mktmpdir do |dir|
      charge_log = File.join(dir, "charges.txt")
      _session, turn, action = park_charge(charge_log)

      Xeno::TurnJob.define_singleton_method(:perform_later) { |*| raise IOError, "queue down" }
      begin
        assert_raises(IOError) { Xeno::Inputs.approve!(action) }
      ensure
        Xeno::TurnJob.singleton_class.remove_method(:perform_later)
      end

      assert_equal "pending_approval", action.reload.status,
        "a lost enqueue must not strand a committed approval"
      assert_equal "waiting", turn.reload.status
      assert_nil action.resolved_at

      # The human retries; everything lands this time.
      assert_enqueued_with(job: Xeno::TurnJob, args: [ turn.id ]) do
        Xeno::Inputs.approve!(action.reload)
      end
      assert_equal "pending", turn.reload.status
      assert_equal :completed, Xeno::TurnRunner.new(Xeno::Turn.find(turn.id)).run
      assert_equal [ "charged 4200" ], File.readlines(charge_log).map(&:strip)
    end
  end

  test "kill between commit and enqueue (deferred-enqueue backend): the reaper recovers the orphan" do
    Dir.mktmpdir do |dir|
      charge_log = File.join(dir, "charges.txt")
      _session, turn, action = park_charge(charge_log)

      out, status = Open3.capture2e(
        { "RAILS_ENV" => "test", "LC_ALL" => "en_US.UTF-8", "RUBYOPT" => "-Eutf-8",
          "ACTION_ID" => action.id.to_s },
        "bin/rails", "runner", SCRIPT, chdir: DUMMY_ROOT
      )
      refute status.success?
      assert_equal 9, status.termsig, "the approver must die by signal 9 (output: #{out})"
      refute_includes out, "UNREACHABLE"

      # The orphan the review called out: resolution committed, no job.
      assert_equal "approved", action.reload.status
      assert_equal "pending", turn.reload.status
      refute File.exist?(charge_log), "the tool must not have run yet"

      # The backstop: one reaper sweep re-enqueues it; the turn completes.
      rescued = nil
      assert_enqueued_with(job: Xeno::TurnJob, args: [ turn.id ]) do
        rescued = Xeno::Reaper.sweep!(stale_before: 1.second.from_now)
      end
      assert_includes rescued.map(&:id), turn.id

      assert_equal :completed, Xeno::TurnRunner.new(Xeno::Turn.find(turn.id)).run
      assert_equal "completed", turn.reload.status
      assert_equal [ "charged 4200" ], File.readlines(charge_log).map(&:strip),
        "the approved tool ran exactly once, after recovery"
    end
  end
end
