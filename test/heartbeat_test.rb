require "test_helper"

# M1(a) regression: a model call or tool body slower than turn_stale_after
# must NOT be reclaimed mid-flight. The runner's background heartbeat keeps
# the claim visibly alive while the worker thread is buried in the call;
# before the fix the heartbeat only moved at step boundaries, so a competing
# claim! (or the reaper) could steal a live turn and run the work twice.
class HeartbeatTest < ActiveSupport::TestCase
  # Real threads must see each other's committed rows.
  self.use_transactional_tests = false

  STALE_AFTER = 1.5 # seconds; heartbeat_interval derives to ~0.37s

  class SlowTool < Xeno::Tool
    description "Takes longer than the staleness window."

    def execute
      sleep STALE_AFTER + 1.0
      { ok: true }
    end
  end

  setup do
    @old_stale = Xeno.config.turn_stale_after
    Xeno.config.turn_stale_after = STALE_AFTER
    @sessions = []
    @threads = []
  end

  teardown do
    Xeno.config.turn_stale_after = @old_stale
    # The runner must be fully done before rows are destroyed under it.
    @threads.each { |t| t.join(15) || t.kill }
    @sessions.each do |session|
      chat = session.chat
      session.destroy
      chat.destroy
    end
  end

  def start_session(definition)
    session = Xeno::Session.open!(message: "go", definition: definition)
    @sessions << session
    [ session, session.turns.order(:sequence).last ]
  end

  # The main thread observes the runner thread's committed writes — reads
  # must bypass ActiveRecord's per-connection query cache.
  def fresh(turn)
    Xeno::Turn.uncached { Xeno::Turn.find(turn.id) }
  end

  def run_in_thread(turn, definition)
    thread = Thread.new { Xeno::TurnRunner.new(turn, definition: definition).run }
    @threads << thread
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 10
    until fresh(turn).status == "running"
      # Surface an early death (exception or a lost claim) instead of timing out.
      assert_equal :running_still, thread.value unless thread.alive?
      flunk "turn never started running" if Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline
      sleep 0.05
    end
    thread
  end

  test "a model call slower than turn_stale_after is not reclaimed mid-flight" do
    start_fake_llm do |_body|
      sleep STALE_AFTER + 1.0
      FakeLLM.text("slow but alive")
    end
    definition = TestDefinition.new
    _session, turn = start_session(definition)

    runner_thread = run_in_thread(turn, definition)
    sleep STALE_AFTER + 0.5 # well past the staleness window, still mid-call

    assert_nil fresh(turn).claim!,
      "a live-but-slow model call must keep the claim fresh (heartbeat)"

    assert_equal :completed, runner_thread.value
    assert_equal "completed", fresh(turn).status
    assert_equal 0, fresh(turn).attempts, "no reclaim means no crash evidence on the ladder"
  end

  test "a tool body slower than turn_stale_after is not reclaimed mid-flight" do
    start_fake_llm do |body|
      if FakeLLM.tool_result?(body)
        FakeLLM.text("done")
      else
        FakeLLM.tool_call("slow_tool", {}, id: "call_slow_#{SecureRandom.hex(4)}")
      end
    end
    definition = TestDefinition.new(tools: { "slow_tool" => SlowTool })
    _session, turn = start_session(definition)

    runner_thread = run_in_thread(turn, definition)
    sleep STALE_AFTER + 0.5 # the tool is still sleeping; the window has passed

    assert_nil fresh(turn).claim!,
      "a live-but-slow tool body must keep the claim fresh (heartbeat)"

    assert_equal :completed, runner_thread.value
    assert_equal "completed", fresh(turn).status
    assert_equal 1, fresh(turn).actions.where(status: "completed").count,
      "the tool ran exactly once (no mid-flight takeover)"
  end
end
