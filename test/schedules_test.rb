require "test_helper"
require "xeno/schedules"

class SchedulesTest < ActiveSupport::TestCase
  include ActiveJob::TestHelper

  class Gated < Xeno::Tool
    description "Needs approval."
    approval :always

    def execute
      raise "must never run in a schedule"
    end
  end

  # --- discovery ---

  test "dummy schedule is discovered with cron and prompt" do
    schedule = Xeno.definition.schedules["weekly_recap"]

    assert schedule
    assert_equal "0 9 * * 1", schedule.cron
    assert_match(/Summarize the week/, schedule.prompt)
  end

  test "missing cron or empty body are error diagnostics" do
    Dir.mktmpdir do |dir|
      root = Pathname(dir)
      root.join("schedules").mkpath
      root.join("instructions.md").write("hi")
      root.join("schedules/no_cron.md").write("---\ntitle: x\n---\nbody\n")
      root.join("schedules/no_body.md").write("---\ncron: \"* * * * *\"\n---\n")

      definition = Xeno::AgentDefinition.load(root, name: "t")
      messages = definition.diagnostics.map(&:message)
      assert messages.any? { |m| m.include?("no_cron.md") && m.include?("missing `cron:`") }
      assert messages.any? { |m| m.include?("no_body.md") && m.include?("no prompt body") }
      assert_empty definition.schedules
    end
  end

  # --- the job ---

  test "ScheduleJob runs a task-mode session under the app principal" do
    start_fake_llm do |body|
      FakeLLM.text("recap: all good")
    end

    Xeno::ScheduleJob.perform_now("weekly_recap")

    session = Xeno::Session.order(:id).last
    assert_equal "schedule", session.channel
    assert_equal({ "type" => "app", "schedule" => "weekly_recap" }, session.principal)
    assert_equal "completed", session.turns.sole.status
    assert_equal "recap: all good", session.chat.messages_association.order(:id).last.content
    assert_match(/Summarize the week/, session.turns.sole.user_message["contents"].first)
  end

  test "a schedule run that hits an approval gate fails deterministically" do
    start_fake_llm do |body|
      if FakeLLM.tool_result?(body)
        FakeLLM.text("should not get here")
      else
        FakeLLM.tool_call("gated", {}, id: "call_sched_gate")
      end
    end
    definition = TestDefinition.new(tools: { "gated" => Gated })
    session = Xeno::Session.open!(
      message: "do the gated thing", channel: "schedule",
      principal: { "type" => "app" }, definition: definition
    )
    turn = session.turns.sole

    assert_equal :failed, Xeno::TurnRunner.new(turn, definition: definition).run

    turn.reload
    assert_equal "failed", turn.status
    assert_match(/human input/, turn.error["message"])
    assert_equal "denied", turn.actions.sole.status
    assert_includes session.events.pluck(:event_type), "turn.failed"
    refute_includes session.events.pluck(:event_type), "session.waiting"
  end

  # --- the sync ---

  test "sync! writes managed entries, preserves foreign keys, skips development" do
    Dir.mktmpdir do |dir|
      path = Pathname(dir).join("recurring.yml")
      path.write(YAML.dump({
        "production" => {
          "my_own_job" => { "class" => "CleanupJob", "schedule" => "@daily" },
          "xeno_stale_one" => { "class" => "Xeno::ScheduleJob", "args" => [ "gone" ], "schedule" => "@daily" }
        },
        "development" => {}
      }))

      result = Xeno::Schedules.sync!(definition: Xeno.definition, path: path)

      production = result["production"]
      assert production.key?("my_own_job"), "hand-written entries survive"
      refute production.key?("xeno_stale_one"), "stale managed entries are removed"
      entry = production["xeno_weekly_recap"]
      assert_equal "Xeno::ScheduleJob", entry["class"]
      assert_equal [ "weekly_recap" ], entry["args"]
      assert_equal "0 9 * * 1", entry["schedule"]
      dev_schedule_jobs = result["development"].select { |_k, v| v["class"] == "Xeno::ScheduleJob" }
      assert_empty dev_schedule_jobs, "dev never fires user schedules on cadence"
      assert result["development"].key?(Xeno::Schedules::REAPER_KEY),
             "the reaper is runtime infrastructure and runs in development too"

      reloaded = YAML.safe_load_file(path)
      assert_equal result, reloaded
    end
  end

  test "sync! creates a production section when the file is absent" do
    Dir.mktmpdir do |dir|
      path = Pathname(dir).join("recurring.yml")
      result = Xeno::Schedules.sync!(definition: Xeno.definition, path: path)
      assert result.dig("production", "xeno_weekly_recap")
    end
  end

  # --- dev dispatch ---

  test "dev dispatch endpoint fires a schedule by name, dev-gated" do
    Xeno.config.authenticate = ->(_r) { { "user" => "dev" } }

    app_test = self
    integration = ActionDispatch::Integration::Session.new(Rails.application)

    # Hidden outside development.
    integration.post "/agent/v1/dev/schedules/weekly_recap"
    app_test.assert_equal 404, integration.response.status

    ENV["XENO_DEV_ROUTES"] = "1"
    begin
      assert_enqueued_with(job: Xeno::ScheduleJob, args: [ "weekly_recap" ]) do
        integration.post "/agent/v1/dev/schedules/weekly_recap"
      end
      assert_equal 202, integration.response.status

      integration.post "/agent/v1/dev/schedules/nope"
      assert_equal 404, integration.response.status
    ensure
      ENV.delete("XENO_DEV_ROUTES")
      Xeno.config.authenticate = nil
    end
  end
end
