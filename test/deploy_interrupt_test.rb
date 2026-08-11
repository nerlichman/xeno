# frozen_string_literal: true

require "test_helper"
require "sqlite3"

# Deploy-style: a REAL Solid Queue worker is SIGTERMed mid-turn (during
# a slow model call). The graceful-shutdown checkpoint hands the turn back
# (claim released, job re-enqueued) inside the worker's 5s shutdown window,
# and a fresh worker resumes it promptly — no stale-heartbeat wait, no crash
# evidence on the ladder. Two real worker processes share the dummy's dev
# sqlite with this test.
class DeployInterruptTest < ActiveSupport::TestCase
  self.use_transactional_tests = false

  setup do
    skip "deploy arc is sqlite-specific (dev-env subprocesses)" if ENV["DATABASE_URL"]
  end

  DUMMY_ROOT = File.expand_path("dummy", __dir__)
  DEV_DB = File.join(DUMMY_ROOT, "storage", "development.sqlite3")

  def demo_env
    {
      "RAILS_ENV" => "development",
      "LC_ALL" => "en_US.UTF-8",
      "RUBYOPT" => "-Eutf-8",
      "XENO_SOLID_QUEUE" => "1",
      "FAKE_LLM_URL" => @fake.url
    }
  end

  def spawn_worker(log)
    log_file = File.open(log, "a")
    pid = Process.spawn(demo_env, "bin/rails", "solid_queue:start",
                        chdir: DUMMY_ROOT, pgroup: true, out: log_file, err: log_file)
    log_file.close
    pid
  end

  def signal_group(pid, signal)
    Process.kill(signal, -Process.getpgid(pid))
  rescue Errno::ESRCH, Errno::EPERM
    nil
  end

  def wait_until(what, timeout: 45, interval: 0.1)
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout
    loop do
      result = yield
      return result if result

      flunk "timed out waiting for: #{what}" if Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline
      sleep interval
    end
  end

  def db_value(sql, *args)
    SQLite3::Database.new(DEV_DB, readonly: true) { |d| return d.get_first_value(sql, *args) }
  rescue SQLite3::BusyException, SQLite3::CantOpenException
    nil
  end

  test "SIGTERM mid-model-call: the turn is handed back within the shutdown window and a fresh worker finishes it" do
    @fake = start_fake_llm do |body|
      if FakeLLM.tool_result?(body)
        FakeLLM.text("Survived the deploy.")
      else
        sleep 3 # slower than the TERM, faster than SQ's 5s shutdown window
        FakeLLM.tool_call("get_weather", { city: "Austin" }, id: "call_deploy_weather")
      end
    end

    Dir.mktmpdir do |tmp|
      worker = nil
      begin
        FileUtils.rm_f(Dir.glob("#{DEV_DB}*"))
        assert system(demo_env, "bin/rails", "db:prepare", chdir: DUMMY_ROOT, out: File::NULL, err: File::NULL),
          "db:prepare failed"
        assert system(demo_env, "bin/rails", "runner",
          'load Rails.root.join("db/queue_schema.rb")', chdir: DUMMY_ROOT, out: File::NULL, err: File::NULL),
          "queue schema load failed"
        assert system(demo_env, "bin/rails", "runner",
          'Xeno::Session.start!(message: "What is the weather in Austin?")',
          chdir: DUMMY_ROOT, out: File::NULL, err: File::NULL), "session start failed"

        worker = spawn_worker(File.join(tmp, "worker1.log"))

        # The worker is now inside the slow first model call.
        wait_until("first model call in flight") { @fake.requests.size >= 1 }

        # The deploy: graceful stop while the call is in flight.
        signal_group(worker, "TERM")
        wait_until("worker 1 exit") { Process.waitpid(worker, Process::WNOHANG) }
        worker = nil

        # The checkpoint: claim handed back, work re-queued, nothing executed.
        assert_equal "pending", db_value("SELECT status FROM xeno_turns"),
          "the stopping worker must release the claim, not die owning it"
        assert_equal 0, db_value("SELECT attempts FROM xeno_turns"),
          "a graceful interrupt is not crash evidence"
        assert_equal 0, db_value("SELECT COUNT(*) FROM xeno_actions"),
          "the tool batch after the interrupt never started"
        assert_operator db_value("SELECT COUNT(*) FROM solid_queue_jobs WHERE finished_at IS NULL"), :>=, 1,
          "the turn re-enqueued itself for the next worker"

        # The next worker resumes promptly — well inside the 5-minute
        # stale-heartbeat window a mid-step death would have cost.
        resumed_at = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        worker = spawn_worker(File.join(tmp, "worker2.log"))
        wait_until("turn completed on worker 2", timeout: 30) do
          db_value("SELECT status FROM xeno_turns") == "completed"
        end
        assert_operator Process.clock_gettime(Process::CLOCK_MONOTONIC) - resumed_at, :<, 30

        assert_equal "completed", db_value("SELECT status FROM xeno_actions"),
          "the tool ran exactly once, on the fresh worker"
        assert_equal 0, db_value("SELECT attempts FROM xeno_turns")
        content = db_value(<<~SQL)
          SELECT content FROM xeno_messages WHERE role = 'assistant' AND content != '' ORDER BY id DESC LIMIT 1
        SQL
        assert_equal "Survived the deploy.", content
      ensure
        signal_group(worker, "KILL") if worker
        Process.waitpid(worker) rescue nil if worker
      end
    end
  end
end
