# Gem-owned puma config for standalone mode (`xeno server`): the whole
# stack — web + Solid Queue supervisor — inside one Puma process.
threads_count = ENV.fetch("RAILS_MAX_THREADS", 5).to_i
threads threads_count, threads_count

# Loopback by default: development runs with the dev auth bypass, and an
# unauthenticated dev UI must not be exposed to the LAN. Opt out with
# HOST=0.0.0.0 for containers/proxies that need it.
bind "tcp://#{ENV.fetch("HOST", "127.0.0.1")}:#{ENV.fetch("PORT", 3000)}"

plugin :solid_queue if ENV.fetch("SOLID_QUEUE_IN_PUMA", "1") != "0"

# Ctrl-C must win. Live SSE streams (the dev UI's EventSource) are in-flight
# requests, and Puma's default is to wait for in-flight requests :forever —
# an open browser tab made shutdown hang (found by the first manual run).
# Hard-stop leftover streams after 5s; xeno's state is rows, nothing is lost.
force_shutdown_after ENV.fetch("XENO_FORCE_SHUTDOWN_AFTER", 5).to_i
