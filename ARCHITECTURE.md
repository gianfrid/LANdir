# Architecture

Landir's goal is a shared network directory usable from any device (see
"Scope" in [README.md](README.md)). It is delivered through interchangeable
host implementations — `landir.py` (Python, the reference), `src/` (Rust,
containerized), and `app/` (Flutter, phone/desktop) — which must stay
behaviorally identical: same CLI/UX, endpoints, and security rules (see
[SPEC.md](SPEC.md)). `landir.py` is the reference: any behavior change lands
there first (with tests), then is ported to Rust and Dart.

## Shared endpoint model (all implementations)

- `GET /` serves a fixed HTML string with a drag-and-drop / file-picker UI and
  client-side rendering of the downloads list. In secret mode (default)
  `GET /<token>/` serves the page (bare `/<token>` gets a 302 to add the
  trailing slash) and everything else 404s; with `--insecure` the plain paths
  are served instead.
- `POST /upload` parses `multipart/form-data` manually (boundary split,
  `Content-Disposition` filename extraction) and writes each file to the
  uploads directory / FileSink. In secret mode only `POST /<token>/upload`
  is accepted. The page's JS posts to a relative `upload` path, so it
  resolves correctly under either mode.
- `GET /files` returns a JSON listing (newest first); `GET /fl/<name>`
  streams one file as an attachment; `GET /ls/<path>` lists a subdirectory.
  All move under `/<token>/` in secret mode.

## Python — `landir.py`

Single-file, zero-dependency, runs on a bare python3 (3.7+ stdlib only).

- `http.server.ThreadingHTTPServer` with a single `BaseHTTPRequestHandler`
  subclass.
- QR encoder (`qr_matrix` / `qr_terminal` and helpers) is pure stdlib: byte
  mode, EC level M, versions 1-6, Reed-Solomon over GF(256), 8 standard masks
  with penalty selection, ANSI half-block rendering. No QR dependency.
- CLI args only (argparse). No env vars, no config files.

## Rust — `src/` + `Cargo.toml`

Cargo project on axum/tokio, distributed as a distroless container image
(crates pinned in `Cargo.lock`).

- Router in `src/server.rs`, testable in-process via `tower::oneshot` (no
  sockets). Path sanitizers in `src/security.rs` / `src/paths.rs`, page in
  `src/page.rs`, listing in `src/listing.rs`, QR in `src/qr.rs`.
- Same flags, endpoints, and security rules as the Python reference.

## Flutter app — `app/`

One Flutter/Dart codebase for Android, iOS, and Linux desktop (see
[ADR 0001](docs/adr/0001-flutter-multiplatform.md) for why). Layout:

- **`app/lib/src/core/` — pure Dart, no Flutter imports**, testable on the
  host machine with `dart test`. HTTP server on `dart:io` `HttpServer`
  directly (no middleware), ports of `safe_name` / `download_lookup`,
  byte-level multipart parser, `FileSink` interface, static HTML page.
  Tested byte-identical against golden vectors exported from `landir.py`
  by `scripts/export_golden.py`.
- **`app/lib/src/views/` + `app/lib/src/providers/` — Flutter UI layer**
  (Riverpod code-gen providers). Host view (QR via `qr_flutter`, start/stop, port selection,
  secret-token toggle, Android foreground service), client view (QR scan via
  `mobile_scanner`, server registry persisted with `shared_preferences`,
  upload via `file_picker`, file browser, download). Responsive layout:
  side-by-side Host/Client on wide (desktop) windows, bottom-nav tabs on
  phone.
- **Platform channels** (`app/lib/src/platform/`): `MediaStoreFileSink`
  writes to `MediaStore.Downloads` on Android (Kotlin in `MainActivity.kt`);
  `DocumentsFileSink` uses the app Documents directory on iOS; hotspot via
  `LocalOnlyHotspot` on Android API 30+.

## See Also

- [README.md](README.md) — Project overview and running instructions
- [SPEC.md](SPEC.md) — Security rules, testing, and conventions
- [GLOSSARY.md](GLOSSARY.md) — Project terminology
