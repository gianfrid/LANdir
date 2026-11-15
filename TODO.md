# TODO

Remaining work after the Flutter app milestones (M1–M4, all delivered — see
git history and [ADR 0001](docs/adr/0001-flutter-multiplatform.md)).

## Release logistics (needs accounts/keys, not code)

- **Android release signing:** configure a release keystore in
  `app/android/app/build.gradle.kts` (currently debug-signed), then
  `flutter build apk --release`.
- **iOS distribution:** Apple Developer enrollment, then
  `flutter build ios --release` / TestFlight.
- **Linux AppImage:** package the `flutter build linux --release` bundle as an
  AppImage (icon already at `app/linux/runner/resources/app_icon.png`).
- **Device matrix:** document tested Android OEMs (background-killer behavior)
  and iOS versions.
- **Emulator CI:** `adb forward` + Python probes against an emulator in
  GitHub Actions.

## Known operational caveats

- OEM background killers (MIUI et al.) may kill even Android foreground
  services; iOS runs the server foreground-only (see ADR 0001). Documented in
  the app UI and README.
- AP client isolation on some Wi-Fi networks blocks phone↔phone traffic
  regardless of app (same LAN caveat as the desktop version).
