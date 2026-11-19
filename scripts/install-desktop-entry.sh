#!/usr/bin/env bash
# Register the LANdir desktop app with the user's session: installs a
# desktop entry (gianfrid.landir.desktop) and the icon into
# ~/.local/share (no root needed) so GNOME Shell can resolve the window's
# dock/taskbar icon. GNOME matches a running window to a desktop entry by
# the GTK application id / StartupWMClass, so a directly-run AppImage has
# no dock icon without this (same trick as gianfrid.unvisited.desktop).
#
# usage: scripts/install-desktop-entry.sh [/path/to/landir-x86_64.AppImage]
# The AppImage path is written into the entry's Exec line; without an
# argument it is searched in ~/Applications and ~ (rolling downloads).
# Re-running updates the entry in place. Companion uninstall:
# scripts/uninstall-desktop-entry.sh.
set -euo pipefail

cd "$(dirname "$0")/.."
DATA_DIR=${XDG_DATA_HOME:-$HOME/.local/share}
APP_ID=gianfrid.landir
ICON_NAME=landir

find_appimage() {
  if [ $# -ge 1 ]; then
    [ -f "$1" ] || { echo "not a file: $1" >&2; exit 1; }
    echo "$1"
    return
  fi
  for candidate in "$HOME/Applications/landir-x86_64.AppImage" \
      "$HOME/landir-x86_64.AppImage"; do
    if [ -f "$candidate" ]; then echo "$candidate"; return; fi
  done
  echo "no AppImage found (pass its path as an argument)" >&2
  exit 1
}

APP_IMAGE=$(find_appimage "$@")
APP_IMAGE=$(readlink -f "$APP_IMAGE")

# Icons at the standard sizes, like the other app entries; if ImageMagick
# is unavailable, the raw 1024px png in 512x512 is scaled by consumers.
SOURCE_ICON=app/assets/icon.png
[ -f "$SOURCE_ICON" ] || { echo "missing icon source: $SOURCE_ICON" >&2; exit 1; }
if command -v convert >/dev/null; then
  for size in 16 24 32 48 64 128 256 512; do
    install -d "$DATA_DIR/icons/hicolor/${size}x${size}/apps"
    convert "$SOURCE_ICON" -resize "${size}x${size}" \
      "$DATA_DIR/icons/hicolor/${size}x${size}/apps/${ICON_NAME}.png"
  done
else
  install -d "$DATA_DIR/icons/hicolor/512x512/apps"
  cp "$SOURCE_ICON" "$DATA_DIR/icons/hicolor/512x512/apps/${ICON_NAME}.png"
fi

install -d "$DATA_DIR/applications"
cat > "$DATA_DIR/applications/${APP_ID}.desktop" <<EOF
[Desktop Entry]
Type=Application
Name=LANdir
Comment=LAN file drop server and client
Exec="$APP_IMAGE"
Icon=${ICON_NAME}
Terminal=false
StartupWMClass=${APP_ID}
Categories=Network;
EOF

# Refresh the MIME/desktop cache when the tool exists (GNOME Shell also
# watches the directory, so this is best-effort).
update-desktop-database "$DATA_DIR/applications" 2>/dev/null || true

echo "installed ${APP_ID}.desktop (Exec=$APP_IMAGE)"
echo "launch from the app grid, or run the AppImage directly — the dock icon resolves either way"
