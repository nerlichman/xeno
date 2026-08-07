require "test_helper"

# M1(e): the graceful-shutdown checkpoint (AJ Continuation's stopping? probe,
# adopted per the durable-orchestration landscape doc). Between runner steps a
# stopping worker releases the claim and re-enqueues the turn instead of dying
# mid-step and waiting out stale-heartbeat reclaim — a deploy resumes promptly
# on the next worker.
class GracefulShutdownTest < ActiveSupport::TestCase
  include ActiveJob::TestHelper

  class Recorder < Xeno::Tool
    description "Records that it ran."

    cattr_accessor :runs, default: []

    def execute
      self.class.runs << Time.current
      { ok: true }
    end
  end

  setup do
    Recorder.runs = []
    @old_check = Xeno.config.stopping_check
  end

  teardown do
    Xeno.config.stopping_check = @old_check
  end

  def start_session(definition)
    session = Xeno::Session.open!(message: "go", definition: definition)
    [ session, session.turns.order(:sequence).last ]
  end

  test "a stopping worker releases the claim between steps and re-enqueues; the next worker fast-forwards" do
    fake = start_fake_llm do |body|
      if FakeLLM.tool_result?(body)
        FakeLLM.text("done after the deploy")
      else
        FakeLLM.tool_call("recorder", {}, id: "call_shutdown_probe")
      end
    end
    definition = TestDefinition.new(tools: { "recorder" => Recorder })
    _session, turn = start_session(definition)

    # The "deploy": the worker starts stopping right after the first model
    # call returns — before the tool batch is resolved.
    Xeno.config.stopping_check = -> { fake.requests.size >= 1 }

    result = nil
    assert_enqueued_with(job: Xeno::TurnJob, args: [ turn.id ]) do
      result = Xeno::TurnRunner.new(turn, definition: definition).run
    end
    assert_equal :interrupted, result

    turn.reload
    assert_equal "pending", turn.status, "the claim is handed back, not abandoned"
    assert_equal 0, turn.attempts, "an interrupt is not crash evidence"
    assert_empty Recorder.runs, "the tool batch after the probe never started"
    refute turn.session.events.where(event_type: "turn.failed").exists?

    # The next worker: stopping is over, the turn resumes from its checkpoint.
    Xeno.config.stopping_check = -> { false }
    assert_equal :completed, Xeno::TurnRunner.new(Xeno::Turn.find(turn.id), definition: definition).run

    assert_equal "completed", turn.reload.status
    assert_equal 1, Recorder.runs.size, "the tool ran exactly once, on the second worker"
    assert fake.requests.all? { |r| FakeLLM.well_formed_tool_calls?(r) },
      "the resumed transcript is provider-legal"
  end

  test "a worker that claims while already stopping releases immediately, before the first model call" do
    fake = start_fake_llm
    definition = TestDefinition.new
    _session, turn = start_session(definition)

    Xeno.config.stopping_check = -> { true }
    assert_equal :interrupted, Xeno::TurnRunner.new(turn, definition: definition).run

    assert_equal "pending", turn.reload.status
    assert_empty fake.requests, "no model call starts on a stopping worker"
  end

  test "the default probe asks the queue adapter and tolerates adapters without stopping?" do
    start_fake_llm
    definition = TestDefinition.new
    _session, turn = start_session(definition)

    # An adapter predating the stopping? API must never interrupt.
    bare_adapter = Object.new
    Xeno::TurnJob.define_singleton_method(:queue_adapter) { bare_adapter }
    begin
      assert_equal :completed, Xeno::TurnRunner.new(turn, definition: definition).run
    ensure
      Xeno::TurnJob.singleton_class.remove_method(:queue_adapter)
    end
  end
end
