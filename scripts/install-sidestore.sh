#!/usr/bin/env bash
set -euo pipefail

TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/firepick-sidestore.XXXXXX")"
DMG_URL="https://github.com/nab138/iloader/releases/latest/download/iloader-darwin-universal.dmg"

printf 'Downloading the official iloader from %s\n' "$DMG_URL"
curl --fail --location --progress-bar "$DMG_URL" --output "$TMP_DIR/iloader.dmg"

printf 'Opening iloader. Sign in with the DEVICE USER's own Apple ID.\n'
open "$TMP_DIR/iloader.dmg"

printf '\nNext steps:\n'
printf '1. Install LocalDevVPN on the target device.\n'
printf '2. Connect the device by USB and trust this Mac.\n'
printf '3. In iloader, select the device and Install SideStore (Stable).\n'
printf '4. Follow docs/sidestore-install.md on the device.\n'

