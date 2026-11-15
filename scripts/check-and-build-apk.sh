#!/usr/bin/env bash
# One-shot change detector: if any app/ source file changed since the last
# successful check, rebuild the APK via build-apk.sh. Safe to run repeatedly.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="$ROOT/app"
STATE="$ROOT/scripts/.watch-apk-state"
LOG="$ROOT/scripts/watch-apk.log"

# Create the baseline marker only on first run; afterwards it is updated
# after each detected build so only *new* changes trigger a rebuild.
[ -f "$STATE" ] || touch "$STATE"

changed=$(find "$APP" -type f \
  \( -name '*.dart' -o -name '*.yaml' -o -name '*.kt' -o -name '*.java' \
     -o -name '*.xml' -o -name '*.plist' -o -name '*.swift' -o -name '*.png' \
     -o -name '*.gradle.kts' -o -name 'CMakeLists.txt' \) \
  -not -path '*/build/*' \
  -not -path '*/.dart_tool/*' \
  -not -path '*/Pods/*' \
  -newer "$STATE" 2>/dev/null | head -5)

if [ -z "$changed" ]; then
  exit 0
fi

echo "[$(date -Is)] change detected:" >> "$LOG"
echo "$changed" >> "$LOG"
touch "$STATE"
echo "[$(date -Is)] building APK..." >> "$LOG"
if "$ROOT/scripts/build-apk.sh" >> "$LOG" 2>&1; then
  echo "[$(date -Is)] build OK" >> "$LOG"
else
  echo "[$(date -Is)] build FAILED (see $LOG)" >> "$LOG"
fi
