#!/bin/sh
set -eu

server="${1:-http://127.0.0.1:9978}"
source_host="${2:-10.0.2.2}"
port="${FIREPICK_SMOKE_PORT:-18765}"
root="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
fixture="$root/protocol/fixtures/quickjs-smoke.js"

python3 -m http.server "$port" \
    --bind 0.0.0.0 \
    --directory "$root/protocol/fixtures" \
    >/tmp/firepick-smoke-http.log 2>&1 &
http_pid=$!
trap 'kill "$http_pid" 2>/dev/null || true' EXIT INT TERM

curl -fsS -X POST \
    -H 'Content-Type: application/json' \
    -d '{}' \
    "$server/spider-api" >/tmp/firepick-smoke-session.json
session="$(sed -n 's/.*"session"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' /tmp/firepick-smoke-session.json)"
test -n "$session"

api="http://$source_host:$port/$(basename "$fixture")"
payload="$(printf '{"api":"%s","ext":"","jar":"","timeout":30}' "$api")"
curl -fsS -X POST \
    -H 'Content-Type: application/json' \
    -H "x-spider-session: $session" \
    -d "$payload" \
    "$server/spider-api/load" >/tmp/firepick-smoke-load.json

state=""
i=0
while [ "$i" -lt 60 ]; do
    curl -fsS -H "x-spider-session: $session" "$server/spider-api" \
        >/tmp/firepick-smoke-state.json
    state="$(sed -n 's/.*"state"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' /tmp/firepick-smoke-state.json)"
    case "$state" in
        loading|running) sleep 0.3 ;;
        *) break ;;
    esac
    i=$((i + 1))
done
test "$state" = "loaded"

curl -fsS -X POST \
    -H 'Content-Type: application/json' \
    -H "x-spider-session: $session" \
    -d '{"method":"homeContent","args":[false],"timeout":30}' \
    "$server/spider-api/run" >/tmp/firepick-smoke-run.json

i=0
while [ "$i" -lt 60 ]; do
    curl -fsS -H "x-spider-session: $session" "$server/spider-api" \
        >/tmp/firepick-smoke-state.json
    state="$(sed -n 's/.*"state"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' /tmp/firepick-smoke-state.json)"
    case "$state" in
        loading|running) sleep 0.3 ;;
        *) break ;;
    esac
    i=$((i + 1))
done
test "$state" = "done"
grep -q '拾萤运行时测试' /tmp/firepick-smoke-state.json

curl -fsS -X DELETE \
    -H "x-spider-session: $session" \
    "$server/spider-api" >/dev/null

printf 'FongMi QuickJS smoke test passed: %s\n' "$server"
