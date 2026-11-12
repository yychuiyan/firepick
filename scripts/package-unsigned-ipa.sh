#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

xcodegen generate

DERIVED="${FIREPICK_IPA_DERIVED:-$ROOT/.build/ipa-derived}"
STAGE="$(mktemp -d "${TMPDIR:-/tmp}/firepick-ipa-stage.XXXXXX")"
mkdir -p "$DERIVED"
trap 'rm -rf "$STAGE"' EXIT

BUILD_OVERRIDES=()
if [[ -n "${FIREPICK_VERSION:-}" ]]; then
  BUILD_OVERRIDES+=("MARKETING_VERSION=$FIREPICK_VERSION")
fi
if [[ -n "${FIREPICK_BUILD:-}" ]]; then
  BUILD_OVERRIDES+=("CURRENT_PROJECT_VERSION=$FIREPICK_BUILD")
fi

xcodebuild \
  -project Firepick.xcodeproj \
  -scheme Firepick \
  -configuration Release \
  -sdk iphoneos \
  -destination 'generic/platform=iOS' \
  -derivedDataPath "$DERIVED" \
  -clonedSourcePackagesDirPath "$ROOT/Packages/FirepickKit/.build" \
  -disableAutomaticPackageResolution \
  CODE_SIGNING_ALLOWED=NO \
  "${BUILD_OVERRIDES[@]}" \
  build \
  -quiet

APP="$DERIVED/Build/Products/Release-iphoneos/Firepick.app"
if [[ ! -d "$APP" ]]; then
  printf 'Missing built app: %s\n' "$APP" >&2
  exit 1
fi

mkdir -p "$ROOT/artifacts" "$STAGE/Payload"
ditto --norsrc --noextattr --noacl "$APP" "$STAGE/Payload/Firepick.app"

VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Info.plist")"
OUTPUT="$ROOT/artifacts/Firepick-unsigned-${VERSION}.ipa"
PACKAGE="$STAGE/Firepick-unsigned-${VERSION}.ipa"
ditto -c -k --norsrc --noextattr --noacl --keepParent "$STAGE/Payload" "$PACKAGE"

unzip -tq "$PACKAGE"
mv -f "$PACKAGE" "$OUTPUT"
shasum -a 256 "$OUTPUT" > "$OUTPUT.sha256"

printf 'Unsigned IPA: %s\n' "$OUTPUT"
printf 'SHA-256: %s\n' "$(cut -d' ' -f1 "$OUTPUT.sha256")"

