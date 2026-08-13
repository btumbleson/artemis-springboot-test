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
set -euo pipefail

EXTERNAL_PORT="${SERVER_PORT:-3000}"
INTERNAL_PORT="${STARTUP_PROBE_SHIM_INTERNAL_PORT:-18080}"
POLL_INTERVAL="${STARTUP_PROBE_SHIM_POLL_INTERVAL:-2}"

JAR="$(ls target/*.jar build/libs/*.jar 2>/dev/null | grep -v -- "-plain\.jar\$" | head -1)"

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

echo "[startup-probe-shim] serving decoy responses on ${EXTERNAL_PORT} until Artemis reports ready"
while ! is_ready; do
    if ! kill -0 "${JAVA_PID}" 2>/dev/null; then
        echo "[startup-probe-shim] java process died before becoming ready, exiting"
        exit 1
    fi
    printf 'HTTP/1.1 200 OK\r\nContent-Length: 2\r\nConnection: close\r\n\r\nOK' \
        | timeout "${POLL_INTERVAL}" nc -l -w "${POLL_INTERVAL}" "${EXTERNAL_PORT}" >/dev/null 2>&1 || true
done

echo "[startup-probe-shim] Artemis is ready, switching ${EXTERNAL_PORT} -> ${INTERNAL_PORT} to a proxy"
if command -v socat >/dev/null 2>&1; then
    exec socat TCP-LISTEN:"${EXTERNAL_PORT}",fork,reuseaddr TCP:127.0.0.1:"${INTERNAL_PORT}"
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
    echo "[startup-probe-shim] no socat or python3 available to proxy ${EXTERNAL_PORT} -> ${INTERNAL_PORT}; the app will only be reachable on ${INTERNAL_PORT}" >&2
    wait "${JAVA_PID}"
fi
