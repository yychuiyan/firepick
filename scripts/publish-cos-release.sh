#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VERSION="${1:-}"
BUCKET="${2:-${COS_BUCKET:-}}"
REGION="${3:-${COS_REGION:-}}"

if [[ -z "$VERSION" || -z "$BUCKET" || -z "$REGION" ]]; then
  printf 'Usage: %s <version> <bucket> <region>\n' "$0" >&2
  printf 'Example: %s 0.1.1 firepick-1302621537 ap-shanghai\n' "$0" >&2
  exit 2
fi
command -v coscli >/dev/null || {
  printf 'coscli is required.\n' >&2
  exit 1
}

BASE_URL="https://${BUCKET}.cos.${REGION}.myqcloud.com/firepick"
DOWNLOAD_BASE_URL="${FIREPICK_IPA_BASE_URL:-$BASE_URL}"
DOWNLOAD_BASE_URL="${DOWNLOAD_BASE_URL%/}"
FIREPICK_IPA_BASE_URL="$DOWNLOAD_BASE_URL" \
  "$ROOT/scripts/publish-sidestore-source.sh" "$VERSION" "$BASE_URL"

IPA="$ROOT/artifacts/sidestore/$VERSION/Firepick-${VERSION}.ipa"
ICON="$ROOT/artifacts/sidestore/$VERSION/AppIcon-${VERSION}.png"
MANIFEST="$ROOT/artifacts/sidestore/$VERSION/firepick.json"
VERIFY_CURL=(curl)
if [[ -n "${FIREPICK_CURL_DOH_URL:-}" ]]; then
  VERIFY_CURL+=(--doh-url "$FIREPICK_CURL_DOH_URL")
fi

coscli cp \
  "$IPA" \
  "cos://${BUCKET}/firepick/Firepick-${VERSION}.ipa" \
  --acl public-read \
  --meta 'Content-Type:application/octet-stream#Cache-Control:public, max-age=31536000, immutable'

coscli cp \
  "$ICON" \
  "cos://${BUCKET}/firepick/AppIcon-${VERSION}.png" \
  --acl public-read \
  --meta 'Content-Type:image/png#Cache-Control:public, max-age=31536000, immutable'

coscli cp \
  "$MANIFEST" \
  "cos://${BUCKET}/firepick/firepick.json" \
  --acl public-read \
  --meta 'Content-Type:application/json;charset=utf-8#Cache-Control:no-cache, max-age=0'

"${VERIFY_CURL[@]}" -fL --silent --show-error \
  "${BASE_URL}/firepick.json" \
  | jq -e --arg version "$VERSION" '.apps[0].version == $version' >/dev/null
"${VERIFY_CURL[@]}" -fL --silent --show-error \
  --range 0-1023 \
  --output /dev/null \
  "${DOWNLOAD_BASE_URL}/Firepick-${VERSION}.ipa"
"${VERIFY_CURL[@]}" -fIL --silent --show-error \
  "${BASE_URL}/AppIcon-${VERSION}.png" >/dev/null

printf '\nPublished Firepick %s to Tencent COS.\n' "$VERSION"
printf 'SideStore source: %s/firepick.json\n' "$BASE_URL"

