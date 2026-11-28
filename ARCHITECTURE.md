# Architecture

LANdir's goal is a shared network directory usable from any device (see
"Scope" in [README.md](README.md)). It is delivered through interchangeable
host implementations — `landir.py` (Python, the reference), `src/` (Rust,
containerized), and `app/` (Flutter, phone/desktop) — that must interoperate:
same endpoints and security rules (see [SPEC.md](SPEC.md)), so any client
works against any host. `landir.py` is the reference: a behavior change
lands there first (with tests), then is ported.

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
- **Encrypted mode** (app: persisted toggle, default on; CLI hosts:
  `--encrypt`, default off — see
  [ADR 0004](docs/adr/0004-cli-encrypted-mode.md)): no token; the long-term
  X25519 host key rides in the QR fragment (`http://ip:port/#k=<base64url>`);
  only the sealed POST endpoints answer at fixed root paths — `/supload`
  (plaintext = boundary `\r\n` + multipart body), `/sfiles` (empty → sealed
  JSON listing), `/sls` (UTF-8 dir path → sealed listing), `/sfl` (UTF-8 file
  path → sealed file bytes). Request envelope `'L' ‖ ephPub ‖ nonce ‖ ct‖mac`,
  response `'L' ‖ nonce ‖ ct‖mac`; X25519 ‖ HKDF-SHA256 ‖ ChaCha20-Poly1305.
  Every plaintext route (page included) is a blind 404; decrypted bodies flow
  through the same handlers as plaintext (SPEC.md rules unchanged below the
  crypto layer). `landir.py` hand-rolls the crypto in pure stdlib; Rust uses
  `x25519-dalek`/`hkdf`/`sha2`/`chacha20poly1305`; the app uses
  `package:cryptography`. A golden envelope fixture from `landir.py` is
  asserted byte-identical by the Rust suite.

## Python — `landir.py`

Single-file, zero-dependency, runs on a bare python3 (3.7+ stdlib only).

- `http.server.ThreadingHTTPServer` with a single `BaseHTTPRequestHandler`
  subclass.
- QR encoder (`qr_matrix` / `qr_terminal` and helpers) is pure stdlib: byte
  mode, EC level M, versions 1-6, Reed-Solomon over GF(256), 8 standard masks
  with penalty selection, ANSI half-block rendering. No QR dependency.
- Sealed-mode crypto (`--encrypt`) is hand-rolled pure stdlib too: X25519
  (RFC 7748 ladder), HKDF-SHA256 (RFC 5869), ChaCha20-Poly1305 (RFC 8439) in
  `src`-level module functions, all verified against the RFC vectors in
  `tests/test_landir.py`.
- CLI args only (argparse). No env vars, no config files (the one exception is
  `LANDIR_KEY_DIR`, which selects where the encrypted-mode host key is
  persisted).

## Rust — `src/` + `Cargo.toml`

Cargo project on axum/tokio, distributed as a distroless container image
(crates pinned in `Cargo.lock`).

- Router in `src/server.rs`, testable in-process via `tower::oneshot` (no
  sockets); the sealed (`--encrypt`) routes live there too, with the crypto
  in `src/crypto.rs` (`x25519-dalek` / `hkdf` / `sha2` / `chacha20poly1305`,
  same wire format as `landir.py` and the app — golden fixture asserted in
  both suites). Path sanitizers in `src/security.rs` / `src/paths.rs`, page
  in `src/page.rs`, listing in `src/listing.rs`, QR in `src/qr.rs`.
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
  on wide (desktop) windows a segmented Host/Client toggle with a Downloads
  side panel that auto-hides while the download list is empty (a toolbar
  toggle pins it open); bottom-nav tabs on phone.
- **Platform channels** (`app/lib/src/platform/`): `MediaStoreFileSink`
  writes to `MediaStore.Downloads` on Android (Kotlin in `MainActivity.kt`);
  `DocumentsFileSink` uses the app Documents directory on iOS; on desktop
  the host view lets the user pick the Save directory (a folder chooser via
  `file_picker`, persisted with `shared_preferences` — null means the
  default Documents directory); hotspot via `LocalOnlyHotspot` on Android
  API 30+.

## See Also

- [README.md](README.md) — Project overview and running instructions
- [SPEC.md](SPEC.md) — Security rules, testing, and conventions
- [GLOSSARY.md](GLOSSARY.md) — Project terminology
