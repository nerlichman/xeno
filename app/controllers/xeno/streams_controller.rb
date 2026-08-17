# frozen_string_literal: true

module Xeno
  # The session event stream: SSE by default, NDJSON on request (`?format=ndjson` or `Accept:
  # application/x-ndjson`). `?start_index=N` rewinds — events are durable rows, so clients replay
  # history and then follow live. The stream ends at a terminal session status or the configured max
  # duration.
  #
  # Known limitation: ActionController::Live holds a thread per client.
  class StreamsController < ApiController # :nodoc:
    include ActionController::Live

    KEEPALIVE_INTERVAL = 5 # seconds without a write before a ping

    # SSE framing: `id:`/`event:` headers per frame, comment keepalives.
    class SseWriter
      def initialize(stream)
        @stream = stream
        @sse = ActionController::Live::SSE.new(stream)
      end

      def content_type = "text/event-stream"
      def event(record) = @sse.write(record.envelope, event: record.event_type, id: record.index)
      def keepalive = @stream.write(": keepalive\n\n")
      def close = @sse.close
    end

    # NDJSON framing: one envelope per line (type/index live inside the envelope); a bare newline as
    # keepalive — line parsers skip empties.
    class NdjsonWriter
      def initialize(stream)
        @stream = stream
      end

      def content_type = "application/x-ndjson"
      def event(record) = @stream.write("#{JSON.generate(record.envelope)}\n")
      def keepalive = @stream.write("\n")
      def close = @stream.close
    end

    def show
      session = find_owned_session!
      writer = build_writer
      response.headers["Content-Type"] = writer.content_type
      response.headers["Last-Modified"] = Time.now.httpdate # disable buffering middlewares

      cursor = params.fetch(:start_index, 0).to_i
      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      last_write = started

      batch_limit = Xeno.config.stream_catch_up_batch
      loop do
        events = session.events.where(index: cursor..).order(:index).limit(batch_limit).to_a
        events.each do |event|
          writer.event(event)
          cursor = event.index + 1
        end
        last_write = Process.clock_gettime(Process::CLOCK_MONOTONIC) if events.any?

        # A full batch means more history is waiting — keep paging through the catch-up without
        # sleeping or ending on a terminal status.
        next if events.size == batch_limit

        break unless session.reload.active?
        break if stream_expired?(started)
        # A graceful stop must not wait out the in-flight-request window. The stream is resumable by
        # design, so close it and let the server exit; the 5s force cap in the puma config is the
        # backstop.
        break if server_shutting_down?

        # A quiet stream never writes, so a dead client would never raise and this thread would poll
        # forever — keepalives make disconnects visible.
        if Process.clock_gettime(Process::CLOCK_MONOTONIC) - last_write > KEEPALIVE_INTERVAL
          writer.keepalive
          last_write = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        end

        sleep Xeno.config.stream_poll_interval
      end
    rescue ActionController::Live::ClientDisconnected, IOError
      # the client went away — nothing to clean up, events are durable
    ensure
      writer&.close
    end

    private

    def build_writer
      if params[:format] == "ndjson" || request.headers["Accept"].to_s.include?("application/x-ndjson")
        NdjsonWriter.new(response.stream)
      else
        SseWriter.new(response.stream)
      end
    end

    def stream_expired?(started)
      max = Xeno.config.stream_max_duration
      max && Process.clock_gettime(Process::CLOCK_MONOTONIC) - started > max
    end

    def server_shutting_down?
      check = Xeno.config.stream_shutdown_check
      return !!instance_exec(&check) if check

      !!puma_server&.shutting_down?
    rescue StandardError
      false
    end

    # ActionController::Live runs the action on its own thread, so Puma's thread-local
    # Server.current is nil here. Find the process's server instance once per connection.
    def puma_server
      return nil unless defined?(Puma::Server)

      @puma_server ||= Puma::Server.current || ObjectSpace.each_object(Puma::Server).first
    end
  end
end
