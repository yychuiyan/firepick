#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VENDOR="$ROOT/third_party"
mkdir -p "$VENDOR"

source "$ROOT/vendor/upstream.lock"

clone_at() {
  local name="$1"
  local url="$2"
  local revision="$3"
  local target="$VENDOR/$name"
  if [[ ! -d "$target/.git" ]]; then
    git clone --filter=blob:none --no-checkout "$url" "$target"
  fi
  git -C "$target" fetch --depth 1 origin "$revision"
  git -C "$target" checkout --detach "$revision"
}

clone_at fongmi-tv https://github.com/FongMi/TV.git "$fongmi_tv_revision"
clone_at catvod-spider https://github.com/FongMi/CatVodSpider.git "$catvod_spider_revision"
clone_at quickjs https://github.com/FongMi/quickjs.git "$quickjs_revision"
clone_at mpv https://github.com/FongMi/mpv.git "$mpv_revision"

QUICKJS_PATCH="$ROOT/vendor/patches/fongmi-quickjs-bundled.patch"
if ! git -C "$VENDOR/fongmi-tv" apply --reverse --check "$QUICKJS_PATCH" 2>/dev/null; then
  git -C "$VENDOR/fongmi-tv" apply "$QUICKJS_PATCH"
fi

RUNTIME_PATCH="$ROOT/vendor/patches/fongmi-runtime-signers.patch"
if ! git -C "$VENDOR/fongmi-tv" apply --reverse --check "$RUNTIME_PATCH" 2>/dev/null; then
  git -C "$VENDOR/fongmi-tv" apply "$RUNTIME_PATCH"
fi

printf 'Pinned upstream sources are ready in %s\n' "$VENDOR"

