#!/usr/bin/env bash
# Copy shared files from the main project into the phone app's assets.
# Run after changing devices.json or the TV screensaver code.
set -euo pipefail
cd "$(dirname "$0")/.."
ROOT=..
if [ ! -f "$ROOT/tv-screensaver/build/tv-screensaver.apk" ] || [ "${1:-}" = "--rebuild" ]; then
  "$ROOT/tv-screensaver/build.sh"
fi
cp "$ROOT/devices.json" assets/devices.json
cp "$ROOT/tv-screensaver/build/tv-screensaver.apk" assets/tv-screensaver.apk
echo "Synced assets/devices.json and assets/tv-screensaver.apk"
