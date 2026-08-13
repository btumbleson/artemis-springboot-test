#!/usr/bin/env bash
# Temporary workaround for Laravel Cloud's beta Java/Spring Boot support: its startup
# probe kills the container ~15s after launch, long before Artemis (Liquibase +
# Hibernate + Hazelcast) can finish booting. Laravel Cloud infra confirmed the fix is
# to extend the probed port's uptime until Java is actually listening and ready.
#
# This script does that: it starts Artemis on an internal port, answers the external
# (probed) port with a decoy response until Artemis's own readiness endpoint reports
# UP, then switches the external port over to a proxy in front of the real app.
#
# Not used by any other deployment path (docker/artemis/Dockerfile has its own
# HEALTHCHECK with a 600s start-period and doesn't invoke this script).
#
# Wire this in as the Laravel Cloud "Start command":
#   bash scripts/laravel-cloud/startup-probe-shim.sh
set -uo pipefail

EXTERNAL_PORT="${SERVER_PORT:-3000}"
INTERNAL_PORT="${STARTUP_PROBE_SHIM_INTERNAL_PORT:-18080}"
POLL_INTERVAL="${STARTUP_PROBE_SHIM_POLL_INTERVAL:-2}"

echo "[startup-probe-shim] pwd=$(pwd)"
echo "[startup-probe-shim] target/: $(ls -la target 2>&1)"
echo "[startup-probe-shim] build/libs/: $(ls -la build/libs 2>&1)"

JAR="$(ls target/*.jar build/libs/*.jar 2>/dev/null | grep -v -- "-plain\.jar\$" | head -1)"
if [ -z "${JAR}" ]; then
    echo "[startup-probe-shim] FATAL: no runnable jar found under target/ or build/libs/ (see listing above)" >&2
    exit 1
fi
echo "[startup-probe-shim] resolved jar: ${JAR}"

set -e

echo "[startup-probe-shim] starting Artemis on internal port ${INTERNAL_PORT}"
SERVER_PORT="${INTERNAL_PORT}" java -jar "${JAR}" &
JAVA_PID=$!

is_ready() {
    if command -v curl >/dev/null 2>&1; then
        curl -fsS -m 2 "http://127.0.0.1:${INTERNAL_PORT}/management/health/readiness" 2>/dev/null | grep -q '"UP"'
        return $?
    fi
    # Fallback when curl isn't available: a raw HTTP GET over bash's /dev/tcp.
    if ! exec 3<>"/dev/tcp/127.0.0.1/${INTERNAL_PORT}" 2>/dev/null; then
        return 1
    fi
    printf 'GET /management/health/readiness HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n' >&3
    local response
    response="$(timeout 2 cat <&3 || true)"
    exec 3<&- 3>&- 2>/dev/null || true
    [[ "${response}" == *'"UP"'* ]]
}

# A one-shot "nc -l" cycled in a loop only listens for a single connection at a time;
# between one nc process exiting and the next binding, the port isn't listening at
# all, and anything landing in that gap (the startup probe, or real traffic) sees
# "connection refused". Worse, if nc isn't even installed, that loop does nothing at
# all while still claiming to via this script's own log line -- which is exactly what
# happened on Laravel Cloud's runtime image (confirmed: no nc, no socat, no python3;
# only perl). So: try real persistent-listener tools in order, and if none exist,
# fail loudly instead of silently pretending to serve the port.
DECOY_PID=""
if command -v socat >/dev/null 2>&1; then
    socat TCP-LISTEN:"${EXTERNAL_PORT}",fork,reuseaddr \
        SYSTEM:'printf "HTTP/1.1 200 OK\r\nContent-Length: 2\r\nConnection: close\r\n\r\nOK"' &
    DECOY_PID=$!
elif command -v perl >/dev/null 2>&1; then
    perl -e '
        use IO::Socket::INET;
        use IO::Select;
        my $port = shift @ARGV;
        my $server = IO::Socket::INET->new(LocalPort => $port, Listen => 128, Reuse => 1, Proto => "tcp")
            or die "cannot bind $port: $!";
        my $response = "HTTP/1.1 200 OK\r\nContent-Length: 2\r\nConnection: close\r\n\r\nOK";
        while (my $client = $server->accept()) {
            # Drain whatever request bytes are already arriving before responding: closing a
            # socket with unread data still in its receive buffer sends a TCP RST instead of a
            # clean FIN, which showed up as nginx logging "Connection reset by peer" upstream.
            # Bounded to 0.2s in case this is a bare TCP-connect probe that never sends anything.
            my $sel = IO::Select->new($client);
            if ($sel->can_read(0.2)) {
                my $buf;
                $client->recv($buf, 8192);
            }
            print $client $response;
            close $client;
        }
    ' "${EXTERNAL_PORT}" &
    DECOY_PID=$!
elif command -v python3 >/dev/null 2>&1; then
    python3 - "${EXTERNAL_PORT}" <<'PYEOF' &
import http.server, socketserver, sys

PORT = int(sys.argv[1])

class Handler(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        self.send_response(200)
        self.send_header("Content-Length", "2")
        self.end_headers()
        self.wfile.write(b"OK")

    def log_message(self, *args):
        pass

class Server(socketserver.ThreadingMixIn, http.server.HTTPServer):
    daemon_threads = True
    allow_reuse_address = True

Server(("0.0.0.0", PORT), Handler).serve_forever()
PYEOF
    DECOY_PID=$!
elif command -v nc >/dev/null 2>&1; then
    echo "[startup-probe-shim] WARNING: only nc found; falling back to a gappy nc-loop decoy" >&2
    ( while true; do
          printf 'HTTP/1.1 200 OK\r\nContent-Length: 2\r\nConnection: close\r\n\r\nOK' \
              | timeout "${POLL_INTERVAL}" nc -l -w "${POLL_INTERVAL}" "${EXTERNAL_PORT}" >/dev/null 2>&1 || true
      done ) &
    DECOY_PID=$!
else
    echo "[startup-probe-shim] FATAL: none of socat, perl, python3, nc are available to run a decoy listener on ${EXTERNAL_PORT}" >&2
    kill "${JAVA_PID}" 2>/dev/null || true
    exit 1
fi
echo "[startup-probe-shim] decoy listener (pid ${DECOY_PID}) serving ${EXTERNAL_PORT} until Artemis reports ready"

while ! is_ready; do
    if ! kill -0 "${JAVA_PID}" 2>/dev/null; then
        echo "[startup-probe-shim] java process died before becoming ready, exiting"
        kill "${DECOY_PID}" 2>/dev/null || true
        exit 1
    fi
    sleep "${POLL_INTERVAL}"
done

echo "[startup-probe-shim] Artemis is ready, stopping decoy and switching ${EXTERNAL_PORT} -> ${INTERNAL_PORT} to a proxy"
kill "${DECOY_PID}" 2>/dev/null || true
wait "${DECOY_PID}" 2>/dev/null || true
if command -v socat >/dev/null 2>&1; then
    exec socat TCP-LISTEN:"${EXTERNAL_PORT}",fork,reuseaddr TCP:127.0.0.1:"${INTERNAL_PORT}"
elif command -v perl >/dev/null 2>&1; then
    exec perl -e '
        use IO::Socket::INET;
        use IO::Select;

        my ($listen_port, $target_port) = @ARGV;
        my $server = IO::Socket::INET->new(LocalPort => $listen_port, Listen => 128, Reuse => 1, Proto => "tcp")
            or die "cannot bind $listen_port: $!";

        while (my $client = $server->accept()) {
            my $pid = fork();
            next unless defined $pid;
            if ($pid == 0) {
                close $server;
                my $upstream = IO::Socket::INET->new(PeerAddr => "127.0.0.1", PeerPort => $target_port, Proto => "tcp");
                if (!$upstream) { close $client; exit(0); }
                my $sel = IO::Select->new($client, $upstream);
                while (my @ready = $sel->can_read) {
                    for my $fh (@ready) {
                        my $buf;
                        my $n = sysread($fh, $buf, 65536);
                        if (!defined $n || $n == 0) { close $client; close $upstream; exit(0); }
                        my $out = ($fh == $client) ? $upstream : $client;
                        syswrite($out, $buf);
                    }
                }
                exit(0);
            }
            close $client;
        }
    ' "${EXTERNAL_PORT}" "${INTERNAL_PORT}"
elif command -v python3 >/dev/null 2>&1; then
    exec python3 - "${EXTERNAL_PORT}" "${INTERNAL_PORT}" <<'PYEOF'
import asyncio, sys
EXTERNAL_PORT, INTERNAL_PORT = int(sys.argv[1]), int(sys.argv[2])

async def pipe(a, b):
    try:
        while True:
            data = await a.read(65536)
            if not data:
                break
            b.write(data)
            await b.drain()
    finally:
        b.close()

async def handle(reader, writer):
    try:
        r2, w2 = await asyncio.open_connection("127.0.0.1", INTERNAL_PORT)
    except Exception:
        writer.close()
        return
    await asyncio.gather(pipe(reader, w2), pipe(r2, writer))

async def main():
    server = await asyncio.start_server(handle, "0.0.0.0", EXTERNAL_PORT)
    async with server:
        await server.serve_forever()

asyncio.run(main())
PYEOF
else
    echo "[startup-probe-shim] FATAL: none of socat, perl, python3 are available to proxy ${EXTERNAL_PORT} -> ${INTERNAL_PORT}; the app is only reachable on ${INTERNAL_PORT}" >&2
    kill "${JAVA_PID}" 2>/dev/null || true
    exit 1
fi
