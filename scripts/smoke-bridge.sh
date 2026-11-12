#!/bin/sh
set -eu

root="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
adb="${ADB:-/opt/homebrew/share/android-commandlinetools/platform-tools/adb}"
http_port="${FIREPICK_SMOKE_PORT:-18765}"

python3 -m http.server "$http_port" \
    --bind 0.0.0.0 \
    --directory "$root/protocol/fixtures" \
    >/tmp/firepick-bridge-smoke-http.log 2>&1 &
http_pid=$!
trap 'kill "$http_pid" 2>/dev/null || true' EXIT INT TERM

"$adb" shell am force-stop app.firepick.bridge
"$adb" shell am start -W -n app.firepick.bridge/app.firepick.bridge.MainActivity >/dev/null
sleep 2
"$adb" shell uiautomator dump /sdcard/firepick-bridge-smoke.xml >/dev/null
"$adb" exec-out cat /sdcard/firepick-bridge-smoke.xml \
    >/tmp/firepick-bridge-smoke.xml

port="$(sed -n 's/.*地址：https:\/\/127\.0\.0\.1:\([0-9]*\).*/\1/p' /tmp/firepick-bridge-smoke.xml | head -1)"
code="$(sed -n 's/.*一次性配对码：\([0-9]*\).*/\1/p' /tmp/firepick-bridge-smoke.xml | head -1)"
test -n "$port"
test -n "$code"
"$adb" forward "tcp:$port" "tcp:$port" >/dev/null

base="https://127.0.0.1:$port/v1"
token="$(curl -ksS -X POST \
    -H 'Content-Type: application/json' \
    -d "{\"code\":\"$code\"}" \
    "$base/pair" | jq -r .token)"
test -n "$token"

configuration='{"sites":[{"type":3,"api":"http://10.0.2.2:'"$http_port"'/quickjs-smoke.js","key":"quickjs-smoke","name":"QuickJS"}]}'
digest="$(printf '%s' "$configuration" | shasum -a 256 | awk '{print $1}')"
curl -ksS -o /dev/null -X PUT \
    -H "Authorization: Bearer $token" \
    -H 'Content-Type: application/json' \
    --data-binary "$configuration" \
    "$base/configs/$digest"

source='{"type":3,"api":"http://10.0.2.2:'"$http_port"'/quickjs-smoke.js","key":"quickjs-smoke","name":"QuickJS"}'
session="$(curl -ksS -X POST \
    -H "Authorization: Bearer $token" \
    -H 'Content-Type: application/json' \
    -d "{\"configDigest\":\"$digest\",\"source\":$source}" \
    "$base/sessions" | jq -r .sessionId)"
test -n "$session"

curl -ksS -X POST \
    -H "Authorization: Bearer $token" \
    -H 'Content-Type: application/json' \
    -d '{"method":"homeContent","arguments":[false]}' \
    "$base/sessions/$session/invoke" \
    >/tmp/firepick-bridge-smoke-home.json
grep -q '拾萤运行时测试' /tmp/firepick-bridge-smoke-home.json

curl -ksS -X POST \
    -H "Authorization: Bearer $token" \
    -H 'Content-Type: application/json' \
    -d '{"method":"searchContent","arguments":["smoke",false,"1"]}' \
    "$base/sessions/$session/invoke" \
    >/tmp/firepick-bridge-smoke-search.json
grep -q 'search-1' /tmp/firepick-bridge-smoke-search.json

curl -ksS -X DELETE \
    -H "Authorization: Bearer $token" \
    "$base/sessions/$session" >/dev/null

printf 'Firepick Bridge QuickJS smoke test passed: %s\n' "$base"
