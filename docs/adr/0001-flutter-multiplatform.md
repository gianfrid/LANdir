# Flutter multiplatform app for Android, iOS, and Linux desktop

The mobile/desktop client and host app lives in `app/` as a single Flutter/Dart
codebase, rather than native Kotlin or per-platform code. Flutter was chosen
because one codebase ships Android, iOS, and a Linux desktop admin view —
the project goal is multiplatform release, and maintaining three native
codebases was not viable. The alternative (native Kotlin + separate iOS app)
was considered and rejected: it would triple the implementation cost for the
same feature set.

Consequences that are deliberate, not accidental:

- **iOS runs the server foreground-only.** Apple suspends backgrounded apps;
  there is no reliable way to keep the HTTP server alive in the background.
  This is documented and surfaced as an in-app warning. Android uses a
  foreground service (`flutter_foreground_task`) and survives screen-off.
- **Storage goes through a `FileSink` interface** (`MediaStore.Downloads` on
  Android via platform channel, app Documents directory on iOS with
  `UIFileSharingEnabled`). Received files are always visible in the native
  Files app on both platforms.
- **Hotspot hosting:** on Android API 30+ the app requests
  `LocalOnlyHotspot` (no location permission needed); on iOS the user enables
  Personal Hotspot manually. The phone's hotspot/LAN IP is auto-detected via
  `NetworkInterface.list()` and encoded in the QR code.
- **Dependency policy:** only well-known, audited pub.dev packages, each added
  when its milestone needs it (`qr_flutter`, `flutter_foreground_task`,
  `path_provider`, `mobile_scanner`, `file_picker`, `shared_preferences`,
  `flutter_launcher_icons`). The zero-dependency rule applies to `landir.py`
  only, not to the Flutter app.
- **Security parity is enforced by golden vectors:** `scripts/export_golden.py`
  exports adversarial fixtures from `landir.py`; the pure-Dart core
  (`app/lib/src/core/`, no Flutter imports) is tested byte-identical against
  them with `dart test`.
- **License:** AGPL-3.0-or-later, same as the rest of the repo.
  minSdk 26, iOS 15+.

Status: accepted
