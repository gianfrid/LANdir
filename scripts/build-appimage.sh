#!/usr/bin/env bash
# Build the Linux AppImage and leave it at the repo root as
# landir-x86_64.AppImage. Called by the release.yml and rolling.yml
# workflows, so both channels build the artifact from the same recipe;
# runnable locally with just the Flutter SDK and the Linux desktop build
# deps (ninja, libgtk-3-dev) installed.
set -euo pipefail

cd "$(dirname "$0")/.."

(cd app && flutter pub get && flutter build linux --release)

# Stage the AppDir in a scratch dir; only the packed AppImage lands in the
# repo tree.
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
APPDIR="$WORK/AppDir"

# The bundle's runner resolves lib/ and data/ relative to the executable,
# so the whole bundle lives under usr/bin — linuxdeploy's usual usr/bin +
# usr/lib split would break it.
BUNDLE=app/build/linux/x64/release/bundle
install -d "$APPDIR/usr/bin"
cp -r "$BUNDLE"/* "$APPDIR/usr/bin/"
cp app/assets/icon.png "$APPDIR/.DirIcon"
cp app/assets/icon.png "$APPDIR/landir.png"
cat > "$APPDIR/landir.desktop" <<'EOF'
[Desktop Entry]
Type=Application
Name=Landir
Exec=landir_app
Icon=landir
Categories=Network;
EOF
printf '%s\n' '#!/bin/sh' \
  'exec "$(dirname "$(readlink -f "$0")")/usr/bin/landir_app" "$@"' \
  > "$APPDIR/AppRun"
chmod +x "$APPDIR/AppRun"

# appimagetool has no usable stable release (the 1.9.x tags are the
# in-progress rewrite, which hangs); the continuous build is the supported
# tool. Timeouts/retries keep a stalled CDN connection from hanging CI.
wget -q --timeout=30 --tries=3 -O "$WORK/appimagetool" \
  "https://github.com/AppImage/appimagetool/releases/download/continuous/appimagetool-x86_64.AppImage"
chmod +x "$WORK/appimagetool"

# APPIMAGE_EXTRACT_AND_RUN works with and without usable FUSE (GitHub
# runners have none), so it is used unconditionally.
ARCH=x86_64 APPIMAGE_EXTRACT_AND_RUN=1 "$WORK/appimagetool" "$APPDIR" landir-x86_64.AppImage

echo "AppImage written to $(pwd)/landir-x86_64.AppImage"
