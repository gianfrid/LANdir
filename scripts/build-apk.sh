#!/usr/bin/env bash
# Dev helper: build the release APK (arm64) and drop it in ../uploads/
# so it can be picked up from the LANdir uploads directory.
# Release builds are debug-signed (see app/android/app/build.gradle.kts),
# which is fine for sideloading during development.
set -euo pipefail

cd "$(dirname "$0")/../app"
flutter build apk --release --split-per-abi --target-platform=android-arm64
cp build/app/outputs/flutter-apk/app-arm64-v8a-release.apk ../uploads/landir.apk
echo "APK copied to uploads/landir.apk"
