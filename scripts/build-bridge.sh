#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ANDROID_HOME="${ANDROID_HOME:-/opt/homebrew/share/android-commandlinetools}"
JAVA_HOME="${JAVA_HOME:-/opt/homebrew/opt/openjdk@21/libexec/openjdk.jdk/Contents/Home}"

export ANDROID_HOME JAVA_HOME
cd "$ROOT/apps/bridge"
./gradlew :app:assembleDebug
printf 'APK: %s\n' "$ROOT/apps/bridge/app/build/outputs/apk/debug/app-debug.apk"

