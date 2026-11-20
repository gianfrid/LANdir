# Sealed endpoints and app-side crypto are a Dart-host-only parity exception

Status: accepted

## Context

`landir.py` (the reference), the Rust implementation, and the browser UI all
speak the same plaintext HTTP contract under `/<token>/`. The deferred design
[docs/design/001-qr-paired-app-encryption.md](../design/001-qr-paired-app-encryption.md)
adds transport encryption for **app clients only**: the Flutter host carries a
long-term X25519 **host key** in the QR fragment (`#k=`), serves sealed
endpoints (`supload`/`sfiles`/`sls`/`sfl`), and the app client pins that key
and seals every request. Generic browsers stay on the plaintext contract —
nothing in the web platform authenticates first-load JS over plain HTTP, so
there is no browser-side equivalent to build (see the design doc's rejected
variants).

This mirrors ADR 0002's `--url` precedent: a capability that only exists where
the Dart host runs, recorded as a documented exception instead of forcing
parity that cannot work.

## Decision

The sealed endpoints (`POST /<token>/supload|sfiles|sls|sfl`, envelope
`'L' ‖ ephPub ‖ nonce ‖ ct+mac` in, `'L' ‖ nonce ‖ ct+mac` out; X25519 ‖
HKDF-SHA256 ‖ ChaCha20-Poly1305) and the client-side pinning live **only in the
Flutter app** (`app/lib/src/core/crypto.dart`, `server.dart`, `client.dart`).
`landir.py` and the Rust server are unchanged: no crypto, plaintext endpoints,
QRs without `#k=`. App clients talking to a CLI host detect the missing `#k=`
and use plaintext mode with a visible "Not encrypted" badge; a pinned server
is always sealed — never a silent fallback.

## Consequences

- **Parity rule exception (like ADR 0002).** SPEC.md's cross-implementation
  parity covers CLI, plaintext endpoints, and the four security rules — all
  unchanged. The sealed endpoints and the QR `#k=` fragment are Dart-app-only.
- **SPEC.md's security rules are untouched.** Sealed bodies are decrypted
  first and then flow through the existing handlers: `safeName()` still
  applies to decrypted filenames, traversal still lands inside the upload
  directory, no reflection, static page, timestamp suffix (covered by
  `test/core/sealed_server_test.dart`).
- **The host key is persisted in the app-support directory**, never under
  `uploads/`; the host stores and serves plaintext by design — this is
  transport confidentiality, not at-rest secrecy.
- **The app binary becomes a trust root** (already noted as a residual in the
  design doc); the release APK signing story matters more once this ships.
- **CLI hosts keep their plaintext + token model**, including their URLs and
  QRs, unchanged.
