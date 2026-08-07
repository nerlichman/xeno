require "test_helper"
require "net/http"
require "sqlite3"

# THE Definition of Done — the README arc, end to end, with real processes:
#
#   scaffolded agent dir (the dummy's, incl. the 10-line approval-gated
#   charge_card tool) → message over HTTP → a REAL Solid Queue worker runs
#   the turn and PARKS on the approval → kill -9 the worker → restart a
#   fresh one → approve over HTTP → the turn resumes exactly where it
#   stopped → final answer → the live SSE stream shows the full story.
#
# Three real processes (puma server, SQ worker, this test) share only the
# dummy app's development sqlite database. The fake LLM lives here.
class DemoAcceptanceTest < ActiveSupport::TestCase
  self.use_transactional_tests = false

  setup do
    # This arc deliberately drives the dummy's development sqlite stack
    # (three processes sharing one file). A DATABASE_URL portability run
    # would propagate into the spawned dev processes and point every
    # environment at one external database — not the scenario under test.
    skip "demo arc is sqlite-specific (dev-env subprocesses)" if ENV["DATABASE_URL"]
  end

  DUMMY_ROOT = File.expand_path("dummy", __dir__)
  DEV_DB = File.join(DUMMY_ROOT, "storage", "development.sqlite3")
  SERVER_PORT = 3411
  BASE = "http://127.0.0.1:#{SERVER_PORT}"
  DEMO_KEY = "demo-key-123"

  def demo_env(extra = {})
    {
      "RAILS_ENV" => "development",
      "LC_ALL" => "en_US.UTF-8",
      "RUBYOPT" => "-Eutf-8",
      "XENO_SOLID_QUEUE" => "1",
      "XENO_DEMO_KEY" => DEMO_KEY,
      "FAKE_LLM_URL" => @fake.url,
      "CHARGE_LOG" => @charge_log
    }.merge(extra)
  end

  def spawn_process(*command, log:)
    log_file = File.open(log, "a")
    pid = Process.spawn(demo_env, *command, chdir: DUMMY_ROOT, pgroup: true,
                                            out: log_file, err: log_file)
    log_file.close
    pid
  end

  def kill_group(pid, signal)
    Process.kill(signal, -Process.getpgid(pid))
  rescue Errno::ESRCH, Errno::EPERM
    nil
  end

  def wait_until(what, timeout: 45, interval: 0.2)
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout
    loop do
      result = yield
      return result if result

      flunk "timed out waiting for: #{what}" if Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline
      sleep interval
    end
  end

  def db
    @db ||= SQLite3::Database.new(DEV_DB, readonly: true).tap { |d| d.busy_timeout = 2000 }
  end

  def db_value(sql, *args)
    SQLite3::Database.new(DEV_DB, readonly: true) { |d| return d.get_first_value(sql, *args) }
  rescue SQLite3::BusyException, SQLite3::CantOpenException
    nil
  end

  def http(method, path, body: nil)
    uri = URI("#{BASE}#{path}")
    request = (method == :post ? Net::HTTP::Post.new(uri) : Net::HTTP::Get.new(uri))
    request["Authorization"] = "Bearer #{DEMO_KEY}"
    if body
      request["Content-Type"] = "application/json"
      request.body = JSON.generate(body)
    end
    Net::HTTP.start(uri.host, uri.port, read_timeout: 30) { |h| h.request(request) }
  end

  # Follow the live SSE stream until +terminal_type+ arrives; returns the
  # parsed envelopes in order.
  def read_stream_until(session_id, terminal_type)
    uri = URI("#{BASE}/agent/v1/sessions/#{session_id}/stream?start_index=0")
    request = Net::HTTP::Get.new(uri)
    request["Authorization"] = "Bearer #{DEMO_KEY}"

    frames = []
    stop = Class.new(StandardError)
    begin
      Net::HTTP.start(uri.host, uri.port, read_timeout: 45) do |connection|
        connection.request(request) do |response|
          buffer = +""
          response.read_body do |chunk|
            buffer << chunk
            while (boundary = buffer.index("\n\n"))
              raw = buffer.slice!(0..boundary + 1)
              data_line = raw.lines.find { |l| l.start_with?("data: ") }
              frames << JSON.parse(data_line.delete_prefix("data: ")) if data_line
            end
            raise stop if frames.any? { |f| f["type"] == terminal_type }
          end
        end
      end
    rescue stop
      # collected everything we needed
    end
    frames
  end

  test "README arc: HTTP -> park -> kill worker -> restart -> approve -> resume -> full story on the stream" do
    @fake = start_fake_llm do |body|
      if FakeLLM.tool_result?(body)
        result = JSON.parse(body["messages"].find { |m| m["role"] == "tool" }["content"])
        FakeLLM.text("Done! I charged $42.00 — receipt #{result['charge_id']}.")
      else
        FakeLLM.tool_call("charge_card", { amount_cents: 4200 }, id: "call_demo_arc")
      end
    end

    Dir.mktmpdir do |tmp|
      @charge_log = File.join(tmp, "charges.txt")
      server = worker = nil

      begin
        # --- a clean stage: fresh dev DB, engine migrations, SQ tables ---
        FileUtils.rm_f(Dir.glob("#{DEV_DB}*"))
        assert system(demo_env, "bin/rails", "db:prepare", chdir: DUMMY_ROOT, out: File::NULL, err: File::NULL),
          "db:prepare failed"
        assert system(demo_env, "bin/rails", "runner",
          'load Rails.root.join("db/queue_schema.rb")', chdir: DUMMY_ROOT, out: File::NULL, err: File::NULL),
          "queue schema load failed"

        # --- processes: web + worker ---
        server = spawn_process("bin/rails", "server", "-p", SERVER_PORT.to_s, log: File.join(tmp, "server.log"))
        wait_until("server health") do
          http(:get, "/agent/v1/health").is_a?(Net::HTTPSuccess) rescue false
        end
        worker = spawn_process("bin/rails", "solid_queue:start", log: File.join(tmp, "worker1.log"))

        # --- 1. send the message over HTTP ---
        response = http(:post, "/agent/v1/sessions", body: { message: "Charge $42 for my upgrade." })
        assert_equal "201", response.code, response.body
        session_id = JSON.parse(response.body)["session_id"]

        # --- 2. the worker runs the turn and PARKS on the approval ---
        wait_until("session parked (waiting)") do
          db_value("SELECT status FROM xeno_sessions WHERE id = ?", session_id) == "waiting"
        end
        refute File.exist?(@charge_log), "the gated tool must not have run"

        # --- 3. kill -9 the worker; nothing but database rows survives ---
        kill_group(worker, "KILL")
        Process.waitpid(worker) rescue nil
        worker = nil

        action_id = db_value(<<~SQL, session_id)
          SELECT a.id FROM xeno_actions a
          JOIN xeno_turns t ON t.id = a.turn_id
          WHERE t.session_id = ? AND a.status = 'pending_approval'
        SQL
        assert action_id, "the parked approval survives the kill"

        # --- 4. a fresh worker + approval over HTTP ---
        worker = spawn_process("bin/rails", "solid_queue:start", log: File.join(tmp, "worker2.log"))
        response = http(:post, "/agent/v1/sessions/#{session_id}/inputs",
                        body: { action_id: action_id, decision: "approve" })
        assert_equal "200", response.code, response.body

        # --- 5. the resumed turn completes; the LIVE stream tells the story ---
        frames = read_stream_until(session_id, "turn.completed")
        types = frames.map { |f| f["type"] }
        assert_equal %w[session.started message.received turn.started step.started
                        step.completed actions.requested input.requested session.waiting
                        action.result step.started step.completed message.completed
                        turn.completed], types, "the event stream must show the full story"

        final = frames.find { |f| f["type"] == "message.completed" }
        assert_equal "Done! I charged $42.00 — receipt ch_4200.", final.dig("data", "content")
        assert_equal (0...frames.size).to_a, frames.map { |f| f.dig("meta", "index") }

        assert_equal [ "charged 4200" ], File.readlines(@charge_log).map(&:strip),
          "the approved tool ran exactly once, in the fresh worker"
        assert_equal "completed",
          db_value("SELECT status FROM xeno_turns WHERE session_id = ?", session_id)
      ensure
        kill_group(worker, "KILL") if worker
        kill_group(server, "KILL") if server
        [ worker, server ].compact.each { |pid| Process.waitpid(pid) rescue nil }
      end
    end
  end
end
