# frozen_string_literal: true

require "test_helper"

class StreamTest < ActionDispatch::IntegrationTest
  setup do
    Xeno.config.authenticate = ->(_request) { { "user" => "test" } }
    Xeno.config.stream_max_duration = 0.6
  end

  teardown do
    Xeno.config.authenticate = nil
    Xeno.config.stream_max_duration = nil
  end

  def completed_session
    start_fake_llm
    definition = TestDefinition.new
    session = Xeno::Session.open!(message: "hi", principal: { "user" => "test" }, definition: definition)
    turn = session.turns.order(:sequence).last
    Xeno::TurnRunner.new(turn, definition: definition).run
    session.finish!("completed")
    session
  end

  def parse_sse(body)
    body.split("\n\n").reject(&:empty?).map do |chunk|
      fields = {}
      chunk.lines.each do |line|
        key, value = line.split(": ", 2)
        fields[key] = value&.strip
      end
      fields["data"] = JSON.parse(fields["data"]) if fields["data"]
      fields
    end
  end

  test "terminal session streams its full history and closes" do
    session = completed_session

    get "/agent/v1/sessions/#{session.id}/stream"

    assert_response :success
    assert_equal "text/event-stream", response.headers["Content-Type"]

    frames = parse_sse(response.body)
    types = frames.map { |f| f["event"] }
    assert_equal session.events.order(:index).pluck(:event_type), types

    ids = frames.map { |f| Integer(f["id"]) }
    assert_equal (0...frames.size).to_a, ids

    first = frames.first
    assert_equal "session.started", first.dig("data", "type")
    assert_equal 0, first.dig("data", "meta", "index")
  end

  test "catch-up reads are bounded: a backlog larger than the batch pages through completely, in order" do
    old_batch = Xeno.config.stream_catch_up_batch
    Xeno.config.stream_catch_up_batch = 5
    session = completed_session
    12.times { |i| Xeno::Event.append!(session, "message.received", { "n" => i }) }
    total = session.events.count
    assert_operator total, :>, 15, "backlog spans several batches"

    get "/agent/v1/sessions/#{session.id}/stream?format=ndjson"

    envelopes = response.body.split("\n").reject(&:empty?).map { |line| JSON.parse(line) }
    assert_equal total, envelopes.size, "every batch was drained before the stream closed"
    assert_equal (0...total).to_a, envelopes.map { |e| e.dig("meta", "index") }
  ensure
    Xeno.config.stream_catch_up_batch = old_batch
  end

  test "NDJSON variant: one envelope per line, same history, same cursor semantics" do
    session = completed_session

    get "/agent/v1/sessions/#{session.id}/stream?format=ndjson"

    assert_response :success
    assert_equal "application/x-ndjson", response.headers["Content-Type"]

    envelopes = response.body.split("\n").reject(&:empty?).map { |line| JSON.parse(line) }
    assert_equal session.events.order(:index).pluck(:event_type), envelopes.map { |e| e["type"] }
    assert_equal (0...envelopes.size).to_a, envelopes.map { |e| e.dig("meta", "index") }

    # Accept-header negotiation and cursor rewind work the same way.
    get "/agent/v1/sessions/#{session.id}/stream?start_index=2",
        headers: { "Accept" => "application/x-ndjson" }
    assert_equal "application/x-ndjson", response.headers["Content-Type"]
    rewound = response.body.split("\n").reject(&:empty?).map { |line| JSON.parse(line) }
    assert_equal 2, rewound.first.dig("meta", "index")
    assert_equal envelopes.size - 2, rewound.size
  end

  test "start_index rewinds to the requested cursor" do
    session = completed_session
    total = session.events.count
    assert_operator total, :>, 3

    get "/agent/v1/sessions/#{session.id}/stream", params: { start_index: 3 }

    frames = parse_sse(response.body)
    assert_equal (3...total).to_a, frames.map { |f| Integer(f["id"]) }
  end

  test "active session streams what exists, then keeps following until the cap" do
    start_fake_llm
    definition = TestDefinition.new
    session = Xeno::Session.open!(message: "hi", principal: { "user" => "test" }, definition: definition) # turn staged, not run

    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    get "/agent/v1/sessions/#{session.id}/stream"
    elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started

    assert_response :success
    frames = parse_sse(response.body)
    assert_equal %w[session.started message.received turn.started], frames.map { |f| f["event"] }
    assert_operator elapsed, :>=, 0.5, "an active session's stream stays open (test cap 0.6s)"
  end

  test "an open stream closes itself when the server begins shutting down" do
    start_fake_llm
    definition = TestDefinition.new
    # Active session, no max_duration: without the shutdown check this
    # stream would only end at the test cap.
    Xeno.config.stream_max_duration = 30
    shutting_down = false
    Xeno.config.stream_shutdown_check = -> { shutting_down }
    session = Xeno::Session.open!(message: "hi", principal: { "user" => "test" }, definition: definition)

    shutting_down = true # flagged before the request; the loop notices on its first poll
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    get "/agent/v1/sessions/#{session.id}/stream"
    elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started

    assert_response :success
    assert_operator elapsed, :<, 5, "the stream must close on shutdown, not wait out the cap"
    frames = parse_sse(response.body)
    assert_equal "session.started", frames.first["event"], "durable history still replays before closing"
  ensure
    Xeno.config.stream_shutdown_check = nil
  end

  test "stream is fail-closed like every endpoint" do
    Xeno.config.authenticate = nil
    session = completed_session

    get "/agent/v1/sessions/#{session.id}/stream"
    assert_response :unauthorized
  end
end
