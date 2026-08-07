require "test_helper"

# The Slack channel, fully offline: signed Events API webhooks in, a fake
# Slack Web API recording chat.postMessage out.
class SlackChannelTest < ActionDispatch::IntegrationTest
  include ActiveJob::TestHelper

  SECRET = "test-signing-secret".freeze

  setup do
    # Load the app definition FIRST (it registers the dummy's channel
    # fixture); our test channel then replaces it for the whole test.
    Xeno.definition

    @fake_slack = FakeSlack.new.start
    @channel = Xeno.channel(:slack) do
      signing_secret SECRET
      bot_token "xoxb-test-token"
    end
    @channel.api_base(@fake_slack.url)
  end

  teardown do
    @fake_slack.stop
    Xeno::Channels.registry.delete(:slack)
  end

  def signed_post(payload, timestamp: Time.now.to_i, secret: SECRET)
    body = JSON.generate(payload)
    base = "v0:#{timestamp}:#{body}"
    signature = "v0=#{OpenSSL::HMAC.hexdigest('sha256', secret, base)}"

    post "/agent/v1/channels/slack/events",
      params: body,
      headers: {
        "Content-Type" => "application/json",
        "X-Slack-Request-Timestamp" => timestamp.to_s,
        "X-Slack-Signature" => signature
      }
  end

  def mention_event(text, channel: "C42", ts: "1000.1", thread_ts: nil, user: "U7")
    {
      type: "event_callback",
      event: {
        type: "app_mention", text: text, channel: channel,
        ts: ts, thread_ts: thread_ts, user: user, team: "T1"
      }.compact
    }
  end

  test "url_verification handshake echoes the challenge" do
    signed_post({ type: "url_verification", challenge: "chal-123" })
    assert_response :success
    assert_equal "chal-123", JSON.parse(response.body)["challenge"]
  end

  test "signature verification fails closed" do
    # Wrong secret.
    signed_post(mention_event("hi"), secret: "wrong-secret")
    assert_response :unauthorized

    # Stale timestamp (replay).
    signed_post(mention_event("hi"), timestamp: 10.minutes.ago.to_i)
    assert_response :unauthorized

    # No channel configured at all.
    Xeno::Channels.registry.delete(:slack)
    signed_post(mention_event("hi"))
    assert_response :not_found
  end

  test "a mention starts a thread-scoped session and the answer posts back" do
    start_fake_llm { |_body| FakeLLM.text("hello from the agent") }

    perform_enqueued_jobs do
      signed_post(mention_event("<@BOT1> what's up?", channel: "C42", ts: "1000.1"))
    end
    assert_response :success

    session = Xeno::Session.order(:id).last
    assert_equal "slack", session.channel
    assert_equal "slack:C42:1000.1", session.continuation_token
    assert_equal "U7", session.principal["user_id"]
    assert_equal "what's up?", session.turns.sole.user_message["contents"].first.strip

    post_payload = @fake_slack.posts.sole
    assert_equal "C42", post_payload["channel"]
    assert_equal "1000.1", post_payload["thread_ts"]
    assert_equal "hello from the agent", post_payload["text"]
    assert_equal "Bearer xoxb-test-token", post_payload["authorization"]
  end

  test "a thread reply continues the same session" do
    start_fake_llm { |body| FakeLLM.text("answer #{body['messages'].count { |m| m['role'] == 'user' }}") }

    perform_enqueued_jobs do
      signed_post(mention_event("first", channel: "C9", ts: "2000.1"))
    end
    session = Xeno::Session.order(:id).last

    perform_enqueued_jobs do
      signed_post(mention_event("second", channel: "C9", ts: "2000.5", thread_ts: "2000.1"))
    end

    assert_equal session.id, Xeno::Session.order(:id).last.id, "no new session for a thread reply"
    assert_equal 2, session.turns.count
    assert_equal "answer 2", @fake_slack.posts.last["text"]
  end

  test "approval over Slack: park posts a prompt, 'approve' resumes, tool runs once" do
    start_fake_llm do |body|
      if FakeLLM.tool_result_in_current_turn?(body)
        FakeLLM.text("charged, receipt sent")
      else
        FakeLLM.tool_call("charge_card", { amount_cents: 4200 }, id: "call_slack_charge")
      end
    end

    charge_log = File.join(Dir.mktmpdir, "charges.txt")
    ENV["CHARGE_LOG"] = charge_log
    begin
      perform_enqueued_jobs do
        signed_post(mention_event("charge me $42", channel: "C11", ts: "3000.1"))
      end

      session = Xeno::Session.order(:id).last
      assert_equal "waiting", session.reload.status
      refute File.exist?(charge_log)

      prompt = @fake_slack.posts.last
      assert_match(/Approval needed/, prompt["text"])
      assert_match(/charge_card/, prompt["text"])
      assert_equal "3000.1", prompt["thread_ts"]

      # The human replies "approve" in the thread.
      perform_enqueued_jobs do
        signed_post(mention_event("approve", channel: "C11", ts: "3000.9", thread_ts: "3000.1"))
      end

      assert_equal "completed", session.turns.sole.reload.status
      assert_equal [ "charged 4200" ], File.readlines(charge_log).map(&:strip)
      assert_equal "charged, receipt sent", @fake_slack.posts.last["text"]

      action = session.turns.sole.actions.sole
      assert_equal "slack", action.resolved_by["type"]
      assert_equal "U7", action.resolved_by["user_id"]
    ensure
      ENV.delete("CHARGE_LOG")
    end
  end

  test "deny over Slack" do
    start_fake_llm do |body|
      if FakeLLM.tool_result_in_current_turn?(body)
        FakeLLM.text("understood, cancelled")
      else
        FakeLLM.tool_call("charge_card", { amount_cents: 4200 }, id: "call_slack_deny")
      end
    end

    perform_enqueued_jobs do
      signed_post(mention_event("charge me", channel: "C12", ts: "4000.1"))
    end
    session = Xeno::Session.order(:id).last

    perform_enqueued_jobs do
      signed_post(mention_event("no", channel: "C12", ts: "4000.9", thread_ts: "4000.1"))
    end

    assert_equal "denied", session.turns.sole.actions.sole.reload.status
    assert_equal "understood, cancelled", @fake_slack.posts.last["text"]
  end

  test "a question is answered by the next thread reply" do
    start_fake_llm do |body|
      if FakeLLM.tool_result_in_current_turn?(body)
        answer = JSON.parse(body["messages"].select { |m| m["role"] == "tool" }.last["content"])["answer"]
        FakeLLM.text("great, #{answer} it is")
      else
        FakeLLM.tool_call("ask_question", { question: "Which day?", choices: [ "Mon", "Tue" ] },
                          id: "call_slack_q_#{body['messages'].size}")
      end
    end

    perform_enqueued_jobs do
      signed_post(mention_event("book a meeting", channel: "C13", ts: "5000.1"))
    end
    prompt = @fake_slack.posts.last
    assert_match(/Which day\?/, prompt["text"])
    assert_match(/Mon \/ Tue/, prompt["text"])

    perform_enqueued_jobs do
      signed_post(mention_event("Tue", channel: "C13", ts: "5000.9", thread_ts: "5000.1"))
    end
    assert_equal "great, Tue it is", @fake_slack.posts.last["text"]
  end

  test "question choices resolve by index, by case-insensitive label, and unrelated replies are held" do
    start_fake_llm do |body|
      if FakeLLM.tool_result_in_current_turn?(body)
        answer = JSON.parse(body["messages"].select { |m| m["role"] == "tool" }.last["content"])["answer"]
        FakeLLM.text("booked for #{answer}")
      else
        FakeLLM.tool_call("ask_question", { question: "Which day?", choices: [ "Monday", "Tuesday" ] },
                          id: "call_hitl_#{body['messages'].size}")
      end
    end

    perform_enqueued_jobs do
      signed_post(mention_event("book it", channel: "C90", ts: "9500.1"))
    end
    session = Xeno::Session.order(:id).last
    question = Xeno::Action.joins(:turn).where(xeno_turns: { session_id: session.id }).sole

    # An unrelated reply is HELD: queued as the next message, never a forced answer.
    perform_enqueued_jobs do
      signed_post(mention_event("actually what's the weather like?", channel: "C90", ts: "9500.2", thread_ts: "9500.1"))
    end
    assert_equal "pending_approval", question.reload.status, "the question survives an unrelated reply"
    held = session.turns.order(:sequence).last
    assert_equal [ "actually what's the weather like?" ], held.user_message["contents"],
      "the unrelated reply became the next staged turn"

    # An index reply resolves to the option's label.
    perform_enqueued_jobs do
      signed_post(mention_event("2", channel: "C90", ts: "9500.3", thread_ts: "9500.1"))
    end
    assert_equal "completed", question.reload.status
    assert_equal({ "answer" => "Tuesday" }, JSON.parse(question.output["content"]))
    assert_includes @fake_slack.posts.map { |p| p["text"] }, "booked for Tuesday"
  end

  test "question labels match case-insensitively" do
    start_fake_llm do |body|
      if FakeLLM.tool_result_in_current_turn?(body)
        FakeLLM.text("noted")
      else
        FakeLLM.tool_call("ask_question", { question: "Which day?", choices: [ "Monday", "Tuesday" ] },
                          id: "call_hitl_ci_#{body['messages'].size}")
      end
    end

    perform_enqueued_jobs do
      signed_post(mention_event("book it", channel: "C91", ts: "9600.1"))
      signed_post(mention_event("tuesday", channel: "C91", ts: "9600.2", thread_ts: "9600.1"))
    end

    session = Xeno::Session.order(:id).last
    question = Xeno::Action.joins(:turn).where(xeno_turns: { session_id: session.id }).sole
    assert_equal({ "answer" => "Tuesday" }, JSON.parse(question.output["content"]),
      "the reply resolves to the canonical option label")
  end

  test "bot messages and subtyped messages are ignored" do
    start_fake_llm

    assert_no_difference "Xeno::Session.count" do
      signed_post({ type: "event_callback",
                    event: { type: "app_mention", text: "loop!", channel: "C1", ts: "1.1",
                             user: "UBOT", bot_id: "B99" } })
      assert_response :success

      signed_post({ type: "event_callback",
                    event: { type: "message", channel_type: "im", subtype: "message_changed",
                             text: "edited", channel: "D1", ts: "2.2", user: "U1" } })
      assert_response :success
    end
  end

  test "stream_replies: the reply posts on the first delta, edits to the final answer, and never double-posts" do
    @channel.stream_replies true
    fake = start_fake_llm { |_body| FakeLLM.text("one two three four five six") }
    fake.stream_delay = 0.6 # trickle the deltas so the 1s edit throttle is exercised

    perform_enqueued_jobs do
      signed_post(mention_event("stream to me", channel: "C80", ts: "9000.1").merge(event_id: "Ev0100"))
    end

    assert fake.requests.all? { |r| r["stream"] }, "the runner streamed the model call"
    assert_equal 1, @fake_slack.posts.size, "one thread message, then edits — no completion double-post"
    first_post = @fake_slack.posts.sole
    assert_equal "9000.1", first_post["thread_ts"]
    assert "one two three four five six".start_with?(first_post["text"].strip),
      "the first post carries the earliest deltas"

    assert_operator @fake_slack.updates.size, :>=, 1
    final = @fake_slack.updates.last
    assert_equal "one two three four five six", final["text"]
    assert_equal first_post["ts"], final["ts"], "edits target the posted message"

    session = Xeno::Session.order(:id).last
    assert_equal "completed", session.turns.sole.status
  ensure
    @channel.stream_replies false
  end

  test "stream_replies: a rate-limited final edit falls back to a completion post" do
    @channel.stream_replies true
    @fake_slack.update_responses = [ :rate_limited ]
    start_fake_llm { |_body| FakeLLM.text("the final answer") }

    perform_enqueued_jobs do
      signed_post(mention_event("stream me", channel: "C81", ts: "9100.1").merge(event_id: "Ev0101"))
    end

    assert_equal 1, @fake_slack.updates.size, "the edit was attempted and 429'd"
    assert_equal 2, @fake_slack.posts.size, "initial streamed post + the reliable completion fallback"
    assert_equal "the final answer", @fake_slack.posts.last["text"]
    assert_equal "completed", Xeno::Session.order(:id).last.turns.sole.status,
      "delivery trouble never touches the turn"
  ensure
    @channel.stream_replies false
    @fake_slack.update_responses = []
  end

  test "a Slack retry storm produces exactly one session and one message (event_id dedup)" do
    start_fake_llm { |_body| FakeLLM.text("stormy") }

    payload = mention_event("storm test", channel: "C77", ts: "7000.1").merge(event_id: "Ev0001")
    assert_difference "Xeno::Session.count", 1 do
      perform_enqueued_jobs do
        3.times { signed_post(payload) } # Slack redelivers on missed acks
        assert_response :success
      end
    end

    session = Xeno::Session.order(:id).last
    assert_equal 1, session.turns.count, "one message, one turn — the retries died at the dedup row"
    assert_equal 1, Xeno::Dedup.where(scope: "slack_event", key: "Ev0001").count
    assert_equal 1, @fake_slack.posts.size
  end

  test "the endpoint acks fast: session work is deferred to the queue" do
    start_fake_llm { |_body| FakeLLM.text("later") }

    payload = mention_event("defer me", channel: "C78", ts: "8000.1").merge(event_id: "Ev0002")
    assert_no_difference "Xeno::Session.count" do
      assert_enqueued_with(job: Xeno::SlackEventJob) do
        signed_post(payload)
      end
      assert_response :success
    end

    # The queue catches up; the session materializes.
    assert_difference "Xeno::Session.count", 1 do
      perform_enqueued_jobs
    end
  end

  test "a DM starts a session too" do
    start_fake_llm { |_body| FakeLLM.text("dm reply") }

    perform_enqueued_jobs do
      signed_post({ type: "event_callback",
                    event: { type: "message", channel_type: "im", text: "hi there",
                             channel: "D77", ts: "6000.1", user: "U7", team: "T1" } })
    end

    session = Xeno::Session.order(:id).last
    assert_equal "slack:D77:6000.1", session.continuation_token
    assert_equal "dm reply", @fake_slack.posts.sole["text"]
  end
end
