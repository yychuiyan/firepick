#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VERSION="${1:-}"
PUBLIC_BASE_URL="${2:-${PUBLIC_BASE_URL:-}}"

if [[ -z "$VERSION" || -z "$PUBLIC_BASE_URL" ]]; then
  printf 'Usage: %s <version> <https-base-url>\n' "$0" >&2
  printf 'Example: %s 0.1.1 https://downloads.example.com/firepick\n' "$0" >&2
  exit 2
fi
if [[ ! "$VERSION" =~ ^[0-9]+(\.[0-9]+){1,3}([-.][A-Za-z0-9]+)*$ ]]; then
  printf 'Invalid version: %s\n' "$VERSION" >&2
  exit 2
fi
if [[ ! "$PUBLIC_BASE_URL" =~ ^https:// ]]; then
  printf 'SideStore source requires a public HTTPS base URL.\n' >&2
  exit 2
fi
command -v jq >/dev/null || {
  printf 'jq is required.\n' >&2
  exit 1
}

PUBLIC_BASE_URL="${PUBLIC_BASE_URL%/}"
IPA_BASE_URL="${FIREPICK_IPA_BASE_URL:-$PUBLIC_BASE_URL}"
IPA_BASE_URL="${IPA_BASE_URL%/}"
BUILD="${FIREPICK_BUILD:-$(date -u +%Y%m%d%H%M)}"
export FIREPICK_VERSION="$VERSION"
export FIREPICK_BUILD="$BUILD"

IPA="$ROOT/artifacts/Firepick-unsigned-${VERSION}.ipa"
if [[ "${FIREPICK_REUSE_IPA:-0}" == "1" ]]; then
  if [[ ! -f "$IPA" ]]; then
    printf 'Cannot reuse missing IPA: %s\n' "$IPA" >&2
    exit 1
  fi
else
  "$ROOT/scripts/package-unsigned-ipa.sh"
fi

ICON_SOURCE="${FIREPICK_ICON_SOURCE:-$ROOT/apps/ios/Firepick/Assets.xcassets/AppIcon.appiconset/AppIcon-1024.png}"
if [[ ! -f "$ICON_SOURCE" ]]; then
  printf 'Missing required source icon: %s\n' "$ICON_SOURCE" >&2
  exit 1
fi

RELEASE_DIR="$ROOT/artifacts/sidestore/$VERSION"
mkdir -p "$RELEASE_DIR"
ditto --norsrc --noextattr --noacl "$IPA" "$RELEASE_DIR/Firepick-${VERSION}.ipa"
ditto --norsrc --noextattr --noacl "$ICON_SOURCE" "$RELEASE_DIR/AppIcon-${VERSION}.png"

DOWNLOAD_URL="$IPA_BASE_URL/Firepick-${VERSION}.ipa"
SOURCE_URL="$PUBLIC_BASE_URL/firepick.json"
RELEASED_AT="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
SIZE="$(stat -f%z "$RELEASE_DIR/Firepick-${VERSION}.ipa")"
DESCRIPTION="${FIREPICK_RELEASE_NOTES:-Firepick ${VERSION}}"
ICON_URL="${FIREPICK_ICON_URL:-$PUBLIC_BASE_URL/AppIcon-${VERSION}.png}"

jq -n \
  --arg version "$VERSION" \
  --arg build "$BUILD" \
  --arg date "$RELEASED_AT" \
  --arg downloadURL "$DOWNLOAD_URL" \
  --argjson size "$SIZE" \
  --arg description "$DESCRIPTION" \
  --arg iconURL "$ICON_URL" \
  '
  {
    name: "Firepick",
    identifier: "com.firepick.sidestore",
    apps: [
      ({
        name: "拾萤",
        bundleIdentifier: "com.firepick.app",
        developerName: "Firepick",
        version: $version,
        versionDate: $date,
        versionDescription: $description,
        downloadURL: $downloadURL,
        iconURL: $iconURL,
        size: $size,
        subtitle: "CatVod 兼容影音客户端",
        localizedDescription: "拾萤 Firepick 是一款面向 iPhone 与 iPad 的 CatVod 兼容影音客户端，支持 iOS 本机与局域网 Android Bridge Provider。",
        absoluteVersion: $version,
        appID: "com.firepick.app",
        versions: [
          {
            version: $version,
            date: $date,
            downloadURL: $downloadURL,
            localizedDescription: $description,
            size: $size,
            absoluteVersion: $version,
            build: $build
          }
        ]
      })
    ]
  }
  ' > "$RELEASE_DIR/firepick.json"

jq empty "$RELEASE_DIR/firepick.json"

printf '\nSideStore source generated:\n'
printf '  Upload IPA: %s\n' "$RELEASE_DIR/Firepick-${VERSION}.ipa"
printf '  IPA download base: %s\n' "$IPA_BASE_URL"
printf '  Upload icon: %s\n' "$RELEASE_DIR/AppIcon-${VERSION}.png"
printf '  Upload manifest as: %s\n' "$SOURCE_URL"
printf '  Manifest file: %s\n' "$RELEASE_DIR/firepick.json"
printf '  Users add source URL: %s\n' "$SOURCE_URL"

