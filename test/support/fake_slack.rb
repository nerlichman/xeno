# A fake Slack Web API: records chat.postMessage and chat.update calls and
# answers ok. Same shape as FakeLLM — thread in the test process, ephemeral
# port. Set `update_responses` to script rate limits (e.g. one 429).
require "webrick"
require "json"

class FakeSlack
  attr_reader :posts, :updates
  attr_accessor :update_responses

  def initialize(port: 0)
    @posts = []
    @updates = []
    @update_responses = []
    @ts_counter = 0
    @mutex = Mutex.new
    @server = WEBrick::HTTPServer.new(
      Port: port,
      BindAddress: "127.0.0.1",
      AccessLog: [],
      Logger: WEBrick::Log.new(File::NULL)
    )
    @server.mount_proc "/chat.postMessage" do |req, res|
      ts = @mutex.synchronize { "9999.#{format('%04d', @ts_counter += 1)}" }
      @posts << JSON.parse(req.body).merge("authorization" => req["Authorization"], "ts" => ts)
      res["Content-Type"] = "application/json"
      res.body = JSON.generate({ ok: true, ts: ts })
    end
    @server.mount_proc "/chat.update" do |req, res|
      @updates << JSON.parse(req.body).merge("authorization" => req["Authorization"])
      scripted = @mutex.synchronize { @update_responses.shift }
      res["Content-Type"] = "application/json"
      if scripted == :rate_limited
        res.status = 429
        res["Retry-After"] = "1"
        res.body = JSON.generate({ ok: false, error: "ratelimited" })
      else
        res.body = JSON.generate({ ok: true, ts: JSON.parse(req.body)["ts"] })
      end
    end
  end

  def start
    @thread = Thread.new { @server.start }
    @thread.abort_on_exception = true
    50.times do
      TCPSocket.new("127.0.0.1", port).close
      break
    rescue Errno::ECONNREFUSED, Errno::ECONNRESET
      sleep 0.05
    end
    self
  end

  def stop
    @server.shutdown
    @thread&.join(5)
  end

  def port = @server.config[:Port]
  def url = "http://127.0.0.1:#{port}"
end
