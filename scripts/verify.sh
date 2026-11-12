#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

swift test --package-path Packages/FirepickKit
swift build \
  --package-path Packages/FirepickKit \
  --triple arm64-apple-ios18.0 \
  --sdk "$(xcrun --sdk iphoneos --show-sdk-path)"

xcodegen generate

DERIVED="$(mktemp -d "${TMPDIR:-/tmp}/firepick-verify.XXXXXX")"
xcodebuild \
  -project Firepick.xcodeproj \
  -scheme Firepick \
  -sdk iphonesimulator \
  -destination 'generic/platform=iOS Simulator' \
  -derivedDataPath "$DERIVED" \
  -clonedSourcePackagesDirPath "$ROOT/Packages/FirepickKit/.build" \
  -disableAutomaticPackageResolution \
  CODE_SIGNING_ALLOWED=NO \
  build

if [[ -x "$ROOT/apps/bridge/gradlew" ]]; then
  "$ROOT/scripts/build-bridge.sh"
fi

printf 'Firepick verification passed.\n'

