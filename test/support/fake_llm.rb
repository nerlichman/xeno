# frozen_string_literal: true

# A deterministic OpenAI-Chat-Completions-compatible server standing in for a model.
# Generalized from spikes/01_parking/fake_llm_server.rb — this is the test suite's
# primary engine (the mockModel equivalent): zero cost, zero flake, fully offline.
#
# RubyLLM reaches it through the Ollama provider (keyless, Chat Completions dialect,
# configurable api base). Point `RubyLLM.configure { |c| c.ollama_api_base = fake.url }`
# at it and build chats with `provider: :ollama, assume_model_exists: true`.
#
# The response is decided by a script block called with the parsed request body:
#
#   fake = FakeLLM.new do |body|
#     if FakeLLM.tool_result?(body)
#       FakeLLM.text("All done.")
#     else
#       FakeLLM.tool_call("charge_card", { amount_cents: 4200 })
#     end
#   end
#
# The block may return a message hash (from .text / .tool_call) or a full response
# envelope; every parsed request body is recorded in `fake.requests` for assertions.
# Runs in a thread inside the test process, so it survives killed worker subprocesses.
require "webrick"
require "json"

class FakeLLM
  attr_reader :requests

  # Seconds to sleep between SSE chunks on streaming requests (0 = send the
  # whole stream in one body; parsers see the same chunk sequence).
  attr_accessor :stream_delay

  def initialize(port: 0, &script)
    @script = script || ->(_body) { FakeLLM.text("ok") }
    @stream_delay = 0
    @requests = []
    @mutex = Mutex.new
    @server = WEBrick::HTTPServer.new(
      Port: port,
      BindAddress: "127.0.0.1",
      AccessLog: [],
      Logger: WEBrick::Log.new(File::NULL)
    )
    mount_endpoints
  end

  def start
    @thread = Thread.new { @server.start }
    @thread.abort_on_exception = true
    wait_until_ready
    self
  end

  def stop
    @server.shutdown
    @thread&.join(5)
    self
  end

  def port
    @server.config[:Port]
  end

  def url
    "http://127.0.0.1:#{port}"
  end

  # --- response builders -----------------------------------------------------

  # A plain assistant text answer (finish_reason: stop). Pass usage to
  # control the reported token counts (compaction/budget tests):
  #   FakeLLM.text("hi", usage: { prompt: 9000, completion: 100 })
  def self.text(content, usage: nil)
    message = { "role" => "assistant", "content" => content }
    message["_usage"] = usage if usage
    message
  end

  # An assistant message requesting one or more tool calls.
  # tool_call("get_weather", { city: "Rome" }) or
  # tool_call([["a", {...}, "call_1"], ["b", {...}, "call_2"]])
  # Pass usage: { prompt:, completion: } to control reported token counts.
  def self.tool_call(name_or_list, arguments = {}, id: nil, usage: nil)
    calls =
      if name_or_list.is_a?(Array)
        name_or_list
      else
        [ [ name_or_list, arguments, id ] ]
      end

    message = {
      "role" => "assistant",
      "content" => nil,
      "tool_calls" => calls.each_with_index.map do |(name, args, call_id), i|
        {
          "id" => call_id || "call_#{name}_#{i + 1}",
          "type" => "function",
          "function" => { "name" => name, "arguments" => JSON.generate(args || {}) }
        }
      end
    }
    message["_usage"] = usage if usage
    message
  end

  # --- request-body predicates for scripts ------------------------------------

  # True once the transcript carries at least one tool result.
  def self.tool_result?(body)
    body["messages"].any? { |m| m["role"] == "tool" }
  end

  # Number of tool-result messages in the transcript.
  def self.tool_result_count(body)
    body["messages"].count { |m| m["role"] == "tool" }
  end

  # True when a tool result appears after the LAST user message — i.e. in
  # the turn currently being driven (multi-turn transcripts carry results
  # from earlier turns, which tool_result? would see).
  def self.tool_result_in_current_turn?(body)
    messages = body["messages"]
    last_user = messages.rindex { |m| m["role"] == "user" }
    return false unless last_user

    messages[last_user..].any? { |m| m["role"] == "tool" }
  end

  def self.last_user_content(body)
    body["messages"].select { |m| m["role"] == "user" }.last&.fetch("content", nil)
  end

  # Providers reject transcripts where an assistant tool_calls message is not
  # immediately followed by a tool result for EVERY requested call id (OpenAI
  # 400s the whole request). True when this request body would be accepted.
  def self.well_formed_tool_calls?(body)
    messages = body["messages"]
    messages.each_with_index.all? do |message, i|
      calls = message["tool_calls"]
      next true unless message["role"] == "assistant" && calls&.any?

      expected = calls.map { |c| c["id"] }.to_set
      following = messages[(i + 1)..].take_while { |m| m["role"] == "tool" }
      answered = following.map { |m| m["tool_call_id"] }.to_set
      expected.subset?(answered)
    end
  end

  private

  def mount_endpoints
    @server.mount_proc "/chat/completions" do |req, res|
      body = JSON.parse(req.body)
      @mutex.synchronize { @requests << body }

      message = @script.call(body)

      if body["stream"] && !(message.is_a?(Hash) && message.key?("choices"))
        chunks = sse_chunks(message, model: body["model"])
        res["Content-Type"] = "text/event-stream"
        if stream_delay.positive?
          delay = stream_delay
          res.chunked = true
          res.body = proc do |out|
            chunks.each do |chunk|
              out.write(chunk)
              sleep delay
            end
          end
        else
          res.body = chunks.join
        end
      else
        response =
          if message.is_a?(Hash) && message.key?("choices")
            message # full envelope supplied by the script
          else
            envelope(message, model: body["model"])
          end
        res["Content-Type"] = "application/json"
        res.body = JSON.generate(response)
      end
    end

    @server.mount_proc "/health" do |_req, res|
      res.body = "ok"
    end
  end

  def envelope(message, model:)
    usage = message.delete("_usage") || {}
    finish_reason = message["tool_calls"] ? "tool_calls" : "stop"
    {
      "id" => "chatcmpl-fake",
      "object" => "chat.completion",
      "model" => model,
      "choices" => [
        { "index" => 0, "message" => message, "finish_reason" => finish_reason }
      ],
      "usage" => {
        "prompt_tokens" => usage[:prompt] || usage["prompt"] || 42,
        "completion_tokens" => usage[:completion] || usage["completion"] || 17
      }
    }
  end

  # The scripted message as a Chat-Completions SSE stream: text content
  # split into word-ish deltas, tool calls delivered whole in one delta
  # (legal — accumulators key on index), usage in the final chunk.
  def sse_chunks(message, model:)
    usage = message.delete("_usage") || {}
    deltas = []

    if message["tool_calls"]
      deltas << { "tool_calls" => message["tool_calls"].each_with_index.map { |tc, i| tc.merge("index" => i) } }
      finish = "tool_calls"
    else
      words = message["content"].to_s.scan(/\S+\s*/)
      words.each_slice([ (words.size / 3.0).ceil, 1 ].max) { |slice| deltas << { "content" => slice.join } }
      deltas << { "content" => "" } if deltas.empty?
      finish = "stop"
    end

    frames = deltas.map { |delta| sse_frame(delta: delta, model: model) }
    frames << sse_frame(delta: {}, model: model, finish_reason: finish,
                        usage: {
                          "prompt_tokens" => usage[:prompt] || usage["prompt"] || 42,
                          "completion_tokens" => usage[:completion] || usage["completion"] || 17
                        })
    frames << "data: [DONE]\n\n"
    frames
  end

  def sse_frame(delta:, model:, finish_reason: nil, usage: nil)
    payload = {
      "id" => "chatcmpl-fake",
      "object" => "chat.completion.chunk",
      "model" => model,
      "choices" => [ { "index" => 0, "delta" => delta, "finish_reason" => finish_reason } ]
    }
    payload["usage"] = usage if usage
    "data: #{JSON.generate(payload)}\n\n"
  end

  def wait_until_ready
    50.times do
      TCPSocket.new("127.0.0.1", port).close
      return
    rescue Errno::ECONNREFUSED, Errno::ECONNRESET
      sleep 0.05
    end
    raise "FakeLLM server failed to start on port #{port}"
  end
end
