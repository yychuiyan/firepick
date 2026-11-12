#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ARCHIVE="$ROOT/artifacts/Firepick.xcarchive"
EXPORT="$ROOT/artifacts/ipa"

mkdir -p "$ROOT/artifacts"
rm -rf "$ARCHIVE" "$EXPORT"

cd "$ROOT"
xcodegen generate

xcodebuild \
  -project Firepick.xcodeproj \
  -scheme Firepick \
  -configuration Release \
  -sdk iphoneos \
  -destination 'generic/platform=iOS' \
  -archivePath "$ARCHIVE" \
  -allowProvisioningUpdates \
  archive

xcodebuild \
  -exportArchive \
  -archivePath "$ARCHIVE" \
  -exportPath "$EXPORT" \
  -exportOptionsPlist "$ROOT/scripts/ExportOptions.plist" \
  -allowProvisioningUpdates

printf 'IPA written to %s\n' "$EXPORT"

