# Landir

Landir turns any device into a shared network directory. One device hosts a
small HTTP server; every other device on the same network can then drop files
onto it — from a plain web browser, no app install required — and download
them again. Files land in a local directory (on phones, in the native Files
app).

> **Warning: LAN-only tool.** Secret mode is on by default (random token URL); pass `--insecure` only on a trusted LAN. There is no upload size limit. Never expose it to the internet — bind it to your local network only.

## Scope

**Goal:** a universal shared directory for the local network. Any device that
can run a Landir host becomes a drop point; any device with a web browser can
use it.

- **Client requirement is minimal: a web browser.** Uploading and downloading
  work from any browser on the network. The Flutter app is an optional,
  richer client (QR scanning, saved servers, file browsing) for when a plain
  browser is not enough — a custom client, not a requirement.
- **Hosts run everywhere:** a bare `python3` (`landir.py`), a Rust binary or
  distroless container (`src/`), or a phone/desktop via the Flutter app
  (`app/`). The set of supported devices and runtimes is expected to grow;
  new hosts are added by porting the same behavior, not by redefining the
  project.
- **One behavior, many implementations.** The Python, Rust, and Dart hosts
  must stay behaviorally identical — same CLI/UX, endpoints, security rules —
  so the directory feels the same from every device. `landir.py` is the
  reference: a behavior change lands there first (with tests), then is
  ported. Parity is the invariant that serves the goal, not the goal itself.

## Layout

- `landir.py` — single-file, zero-dependency Python application (server, HTML page, upload handling, QR code encoder/renderer). Reference implementation; must run on a bare python3.
- `src/` + `Cargo.toml` — Rust implementation (axum/tokio). Same CLI and endpoints; distributed as a container image, so crates are fine here.
- `app/` — Flutter app (Android, iOS, Linux desktop). Hosts the drop server on the phone and acts as a client to any Landir server. Pure-Dart core in `app/lib/src/core/` is tested against golden vectors from `landir.py`. See [ARCHITECTURE.md](ARCHITECTURE.md) and [ADR 0001](docs/adr/0001-flutter-multiplatform.md).
- `tests/test_landir.py` — stdlib-unittest suite for the Python version (no dependencies).
- `uploads/` — default upload target, created on start. Runtime data, do not commit.

## Running

```bash
python3 landir.py [--port PORT] [--dir UPLOADS_DIR] [--insecure]
# defaults: port 8000, uploads in ./uploads, secret mode ON
```

At startup the server prints the URL to open, rendered as a scannable QR code (ANSI half-blocks). If the requested port is occupied, the server automatically falls back to a random available high port (32768-60999), except in the container image with `--url` set (see below).

On an interactive terminal the server shows a full-screen view instead: the QR code and the list of currently-online client IPs stay visible on top (`q` toggles the QR panel), and a scrollable event log below shows who uploaded or downloaded what (arrows/PgUp/PgDn scroll). File-listing polls are never logged as lines — they only keep a client visible in the online list for 10 s after its last request. When output is not a TTY it falls back to plain log lines with the same filtering. This applies to both implementations: `landir.py` uses curses (Unix only — elsewhere it falls back to plain logs), and the Rust binary uses ratatui/crossterm, so it also shows the full-screen UI when the container is run with a TTY (`podman run -it ...`) and plain logs when it is not (e.g. `podman logs`).

Secret mode is the default: the page and upload endpoint live under a fresh random token path (`/<token>/`, `/<token>/upload`) and every other path returns 404; the QR code encodes the full secret URL. Pass `--insecure` (`-i`) to serve on plain `/`, `/upload`, ... URLs instead.

Python 3.7+ standard library only. No packaging, no install step, no config files. Do not introduce dependencies without an explicit request.

## Running in a container

The default `Containerfile` (podman/docker compatible) builds the **Rust**
implementation as a distroless static image (~4.5 MB; static binary ~1.3 MB,
no shell/libc/package manager, runs as UID 65532):

```bash
# build
podman build -f Containerfile -t landir .
# docker build -f Containerfile -t landir .   # also works

# run (-it attaches a TTY so Ctrl+C stops the server; uploads persist to
# ./uploads on the host)
podman run --rm -it -p 8000:8000 -v ./uploads:/app/uploads landir
# open http://<host-ip>:8000/
```

### Publishing on a different host port

The container cannot know which host port you mapped, so always pass `--url`
with the origin clients should use. Without it the printed URL and QR code
advertise the port bound *inside* the container, which is unreachable:

```bash
podman run --rm -it -p 18080:8000 -v ./uploads:/app/uploads \
  landir --url http://192.168.1.50:18080
# QR and printed URL now say http://192.168.1.50:18080/<token>/
```

`--url` takes a full origin (`http` or `https`, host, optional port, no path);
the secret token path is still appended. With `--url` set, an occupied listen
port is a fatal error rather than a silent fallback to a random port, since
the mapping is fixed and a fallback would print a URL that cannot work.

> `--url` exists only in the Rust implementation (the one the container
> ships). `landir.py` and the Flutter app are not run behind a port mapping.

## Rust build (local)

The Rust implementation (`src/`, Cargo project) is the same server — same
flags, same endpoints, same security rules — built on axum/tokio. Unlike the
Python file it is distributed as a container image, so it uses crates
(versions pinned in `Cargo.lock`).

```bash
cargo build --release   # native binary
cargo test              # unit + in-process endpoint tests (no sockets)
# static musl binary for distroless:
cargo build --release --target x86_64-unknown-linux-musl
```

## Flutter app (Android / iOS / Linux)

The `app/` directory is a Flutter project implementing the host server (role #1)
and client (role #2) for Android, iOS, and Linux desktop. The security-critical
core (`app/lib/src/core/`) is pure Dart, tested against golden vectors exported
from `landir.py` via `scripts/export_golden.py`.

```bash
cd app
flutter pub get
dart run build_runner build --delete-conflicting-outputs   # regenerate Riverpod providers
dart test test/core/                                        # pure-Dart core tests (no device)
flutter test                                                # widget tests
flutter analyze

# Run on a connected device or desktop:
flutter run                       # debug build
flutter run -d linux              # Linux desktop

# Release builds:
flutter build apk --release       # Android (sideload; debug-signed until a release key is configured)
flutter build ios --release       # iOS (requires Xcode + Apple Developer account)
flutter build linux --release     # Linux desktop bundle
```

See [GLOSSARY.md](GLOSSARY.md) for terminology.

**Remaining release tasks** (need accounts/keys, not code):

- **Android release signing:** configure a release keystore in
  `app/android/app/build.gradle.kts` (currently debug-signed), then
  `flutter build apk --release`.
- **iOS distribution:** Apple Developer enrollment, then
  `flutter build ios --release` / TestFlight.
- **Linux AppImage:** package the `flutter build linux --release` bundle as an
  AppImage (icon already at `app/linux/runner/resources/app_icon.png`).
- **Device matrix:** document tested Android OEMs (background-killer behavior)
  and iOS versions.

> **Platform caveats:** on iOS the server runs only while the app is in the foreground (Apple suspends backgrounded apps — shown as an in-app warning). On Android a foreground service keeps it alive, but some OEMs (MIUI et al.) may still kill it. AP client isolation on some Wi-Fi networks blocks phone↔phone traffic regardless of app (same LAN caveat as the desktop version). See [ADR 0001](docs/adr/0001-flutter-multiplatform.md).

## Supply chain

- `SBOM.spdx.json` — SPDX SBOM of every third-party crate (regenerate after any
  dependency change with `cargo sbom > SBOM.spdx.json`, requires `cargo install cargo-sbom`)
- `cargo audit` — vulnerability scan of `Cargo.lock` against the RustSec
  advisory database (requires `cargo install cargo-audit`); currently clean
- The container base is `gcr.io/distroless/static-debian13` pinned by
  **digest** (multi-arch index) in the `Containerfile`; on GitHub, Dependabot
  keeps tag+digest and Cargo deps updated automatically (`.github/dependabot.yml`).
  Offline fallback: `./scripts/update-distroless-digest.sh`

## CI / automation (GitHub, free for public repos)

- `.github/workflows/ci.yml` — on every push/PR: Python unittest suite, `cargo test
  --locked`, `cargo audit`, SBOM freshness check (normalized diff), and a
  container build + smoke test with podman
- `.github/dependabot.yml` — weekly updates for the `docker` (Containerfile
  FROM lines, tag+digest) and `cargo` (Cargo.lock) ecosystems
- **Emulator CI (open task):** `adb forward` + Python probes against an
  emulator in GitHub Actions

## See Also

- [ARCHITECTURE.md](ARCHITECTURE.md) — Technical architecture of all three implementations
- [SPEC.md](SPEC.md) — Security rules, testing, and conventions
- [GLOSSARY.md](GLOSSARY.md) — Project terminology
- [docs/adr/0001-flutter-multiplatform.md](docs/adr/0001-flutter-multiplatform.md) — Why the app is Flutter, and its deliberate platform limitations

## License

[AGPL-3.0-or-later](LICENSE)
