#!/usr/bin/env bash
# Workaround for Laravel Cloud's beta Java/Spring Boot support: its health probe kills
# the container ~15s after launch, long before Artemis (Liquibase + Hibernate +
# Hazelcast) finishes booting. Laravel Cloud infra confirmed the fix is to keep the
# probed port answering until Java is actually listening -- and that the probe runs
# continuously, not just once during startup.
#
# Design: a single long-lived gateway owns the external (probed) port for the whole
# life of the container. Artemis runs on an internal port. For each connection the
# gateway tries the internal port; if Artemis is up it pipes the connection through,
# and if it is not up yet it answers 200 OK itself. That means:
#   * the probed port is bound within milliseconds of container start, and never
#     unbound afterwards -- no handoff gap, and nothing to re-satisfy if the probe
#     keeps running forever;
#   * real traffic reaches Artemis as soon as it is listening, with no restart.
#
# The gateway binds dual-stack (:: with V6Only=0) where IO::Socket::IP is available.
# An IPv4-only bind is not sufficient here: this environment is IPv6-native (nginx
# logs clients such as 2600:1f16:e0:...), so a probe connecting over IPv6 or via a
# localhost that resolves to ::1 would be refused by an 0.0.0.0-only listener even
# though nginx, which dials 127.0.0.1, sees it as perfectly healthy.
#
# Not used by any other deployment path (docker/artemis/Dockerfile has its own
# HEALTHCHECK with a 600s start-period and doesn't invoke this script).
#
# Wire this in as the Laravel Cloud "Start command":
#   bash scripts/laravel-cloud/startup-probe-shim.sh
set -uo pipefail

EXTERNAL_PORT="${SERVER_PORT:-3000}"
INTERNAL_PORT="${STARTUP_PROBE_SHIM_INTERNAL_PORT:-18080}"
POLL_INTERVAL="${STARTUP_PROBE_SHIM_POLL_INTERVAL:-5}"

echo "[startup-probe-shim] pwd=$(pwd)"
echo "[startup-probe-shim] target/: $(ls -la target 2>&1)"
echo "[startup-probe-shim] build/libs/: $(ls -la build/libs 2>&1)"

JAR="$(ls target/*.jar build/libs/*.jar 2>/dev/null | grep -v -- "-plain\.jar\$" | head -1)"
if [ -z "${JAR}" ]; then
    echo "[startup-probe-shim] FATAL: no runnable jar found under target/ or build/libs/ (see listing above)" >&2
    exit 1
fi
echo "[startup-probe-shim] resolved jar: ${JAR}"

# ---------------------------------------------------------------------------
# Gateway: bind the probed port first, before Java is even started, so the very
# first probe lands on something that answers.
# ---------------------------------------------------------------------------
GATEWAY_PID=""
if command -v perl >/dev/null 2>&1; then
    perl -e '
        use strict;
        use warnings;
        use IO::Select;
        use POSIX qw(:sys_wait_h);

        my ($listen_port, $target_port) = @ARGV;
        $| = 1;
        $SIG{CHLD} = sub { 1 while waitpid(-1, WNOHANG) > 0 };
        $SIG{PIPE} = "IGNORE";

        # Dual-stack where possible: an IPv4-only listener is invisible to a probe
        # that connects over IPv6 or via a localhost resolving to ::1.
        my $server;
        if (eval { require IO::Socket::IP; 1 }) {
            $server = IO::Socket::IP->new(
                LocalHost => "::",
                LocalPort => $listen_port,
                Listen    => 128,
                ReuseAddr => 1,
                V6Only    => 0,
            );
            print STDERR "[gateway] bound $listen_port dual-stack (IO::Socket::IP)\n" if $server;
        }
        if (!$server) {
            require IO::Socket::INET;
            $server = IO::Socket::INET->new(
                LocalPort => $listen_port,
                Listen    => 128,
                Reuse     => 1,
                Proto     => "tcp",
            ) or die "[gateway] FATAL: cannot bind $listen_port: $!\n";
            print STDERR "[gateway] bound $listen_port IPv4-only (IO::Socket::IP unavailable)\n";
        }
        print STDERR "[gateway] upstream is 127.0.0.1:$target_port\n";

        my $holding = "HTTP/1.1 200 OK\r\nContent-Length: 2\r\nConnection: close\r\n\r\nOK";

        while (1) {
            my $client = $server->accept();
            next unless $client;
            my $pid = fork();
            if (!defined $pid) { close $client; next; }
            if ($pid == 0) {
                close $server;
                require IO::Socket::INET;
                my $up = IO::Socket::INET->new(
                    PeerAddr => "127.0.0.1",
                    PeerPort => $target_port,
                    Proto    => "tcp",
                    Timeout  => 2,
                );
                if (!$up) {
                    # Artemis is not listening yet: answer the probe ourselves. Drain
                    # first, so closing does not leave unread bytes in the receive
                    # buffer (which makes the kernel send RST instead of FIN).
                    my $s = IO::Select->new($client);
                    if ($s->can_read(0.2)) { my $b; sysread($client, $b, 8192); }
                    syswrite($client, $holding);
                    close $client;
                    exit 0;
                }
                my $sel = IO::Select->new($client, $up);
                OUTER: while (my @ready = $sel->can_read()) {
                    for my $fh (@ready) {
                        my $buf;
                        my $n = sysread($fh, $buf, 65536);
                        last OUTER if !defined $n || $n == 0;
                        my $out = (fileno($fh) == fileno($client)) ? $up : $client;
                        my $off = 0;
                        while ($off < length($buf)) {
                            my $w = syswrite($out, $buf, length($buf) - $off, $off);
                            last OUTER if !defined $w;
                            $off += $w;
                        }
                    }
                }
                close $client;
                close $up;
                exit 0;
            }
            close $client;
        }
    ' "${EXTERNAL_PORT}" "${INTERNAL_PORT}" &
    GATEWAY_PID=$!
elif command -v python3 >/dev/null 2>&1; then
    python3 - "${EXTERNAL_PORT}" "${INTERNAL_PORT}" <<'PYEOF' &
import asyncio, socket, sys

EXTERNAL_PORT, INTERNAL_PORT = int(sys.argv[1]), int(sys.argv[2])
HOLDING = b"HTTP/1.1 200 OK\r\nContent-Length: 2\r\nConnection: close\r\n\r\nOK"

async def pipe(a, b):
    try:
        while True:
            data = await a.read(65536)
            if not data:
                break
            b.write(data)
            await b.drain()
    except Exception:
        pass
    finally:
        try:
            b.close()
        except Exception:
            pass

async def handle(reader, writer):
    try:
        r2, w2 = await asyncio.open_connection("127.0.0.1", INTERNAL_PORT)
    except Exception:
        # Upstream not up yet: answer the probe ourselves, draining first.
        try:
            await asyncio.wait_for(reader.read(8192), timeout=0.2)
        except Exception:
            pass
        writer.write(HOLDING)
        try:
            await writer.drain()
        except Exception:
            pass
        writer.close()
        return
    await asyncio.gather(pipe(reader, w2), pipe(r2, writer))

async def main():
    # host=None binds every available interface, which yields a dual-stack listener
    # on an IPv6-enabled host -- the point being not to end up IPv4-only.
    server = await asyncio.start_server(handle, None, EXTERNAL_PORT)
    print(f"[gateway] listening on {EXTERNAL_PORT}, upstream 127.0.0.1:{INTERNAL_PORT}", file=sys.stderr, flush=True)
    async with server:
        await server.serve_forever()

asyncio.run(main())
PYEOF
    GATEWAY_PID=$!
else
    echo "[startup-probe-shim] FATAL: neither perl nor python3 is available to run the gateway on ${EXTERNAL_PORT}" >&2
    exit 1
fi
echo "[startup-probe-shim] gateway (pid ${GATEWAY_PID}) owns ${EXTERNAL_PORT}, forwarding to ${INTERNAL_PORT} once Artemis is up"

# ---------------------------------------------------------------------------
# Artemis itself, on the internal port.
# ---------------------------------------------------------------------------
echo "[startup-probe-shim] starting Artemis on internal port ${INTERNAL_PORT}"
SERVER_PORT="${INTERNAL_PORT}" java -jar "${JAR}" &
JAVA_PID=$!

cleanup() {
    kill "${GATEWAY_PID}" 2>/dev/null || true
    kill "${JAVA_PID}" 2>/dev/null || true
}
trap cleanup TERM INT

# Observability only: report the moment Artemis starts accepting, so the logs show
# how long a full boot actually takes here.
(
    start="${SECONDS}"
    while true; do
        if (exec 3<>"/dev/tcp/127.0.0.1/${INTERNAL_PORT}") 2>/dev/null; then
            exec 3<&- 3>&- 2>/dev/null || true
            echo "[startup-probe-shim] Artemis is accepting on ${INTERNAL_PORT} after $((SECONDS - start))s; gateway now forwarding real traffic"
            break
        fi
        kill -0 "${JAVA_PID}" 2>/dev/null || break
        sleep "${POLL_INTERVAL}"
    done
) &

wait "${JAVA_PID}"
JAVA_STATUS=$?
echo "[startup-probe-shim] java exited with status ${JAVA_STATUS}; shutting down gateway"
kill "${GATEWAY_PID}" 2>/dev/null || true
exit "${JAVA_STATUS}"
