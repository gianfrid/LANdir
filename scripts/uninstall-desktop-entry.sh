#!/usr/bin/env bash
# Remove the files installed by scripts/install-desktop-entry.sh: the
# gianfrid.landir.desktop entry and the landir.png icons from
# ~/.local/share. The AppImage itself (~/Applications or wherever it was
# downloaded) is left alone.
set -euo pipefail

DATA_DIR=${XDG_DATA_HOME:-$HOME/.local/share}
APP_ID=gianfrid.landir
ICON_NAME=landir

rm -f "$DATA_DIR/applications/${APP_ID}.desktop"
count=0
for icon in "$DATA_DIR"/icons/hicolor/*/apps/${ICON_NAME}.png; do
  [ -f "$icon" ] || continue
  rm -f "$icon"
  count=$((count + 1))
done
update-desktop-database "$DATA_DIR/applications" 2>/dev/null || true

if [ "$count" -eq 0 ] && [ ! -f "$DATA_DIR/applications/${APP_ID}.desktop" ]; then
  echo "nothing to uninstall (${APP_ID} was not installed)"
else
  echo "uninstalled ${APP_ID}: desktop entry + $count icon(s)"
fi
