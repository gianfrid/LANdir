#!/usr/bin/env bash
# Dev watcher: rebuild the APK whenever source files under app/ change.
# Polls every 5s (no inotify-tools dependency). Excludes build outputs so
# the build itself never retriggers the watcher.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="$ROOT/app"
MARKER="$(mktemp)"
touch "$MARKER"
LOG="$ROOT/scripts/watch-apk.log"

echo "[$(date -Is)] watcher started, watching $APP" | tee -a "$LOG"

while true; do
  sleep 5
  # Find source files newer than the marker; exclude build/tooling dirs.
  changed=$(find "$APP" -type f \
    \( -name '*.dart' -o -name '*.yaml' -o -name '*.kt' -o -name '*.java' \
       -o -name '*.xml' -o -name '*.plist' -o -name '*.swift' -o -name '*.png' \
       -o -name '*.gradle.kts' -o -name 'CMakeLists.txt' \) \
    -not -path '*/build/*' \
    -not -path '*/.dart_tool/*' \
    -not -path '*/Pods/*' \
    -newer "$MARKER" 2>/dev/null | head -5)
  if [ -n "$changed" ]; then
    echo "[$(date -Is)] change detected:" | tee -a "$LOG"
    echo "$changed" | tee -a "$LOG"
    touch "$MARKER"
    echo "[$(date -Is)] building APK..." | tee -a "$LOG"
    if "$ROOT/scripts/build-apk.sh" >> "$LOG" 2>&1; then
      echo "[$(date -Is)] build OK" | tee -a "$LOG"
    else
      echo "[$(date -Is)] build FAILED (see $LOG)" | tee -a "$LOG"
    fi
  fi
done
