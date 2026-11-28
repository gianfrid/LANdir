# Sealed endpoints and app-side crypto are a Dart-host-only parity exception

Status: accepted

## Context

`landir.py` (the reference), the Rust implementation, and the browser UI all
speak the same plaintext HTTP contract under `/<token>/`. The design
[docs/design/001-qr-paired-app-encryption.md](../design/001-qr-paired-app-encryption.md)
adds transport encryption for **app clients only**: the Flutter host carries a
long-term X25519 **host key** in the QR fragment (`#k=`), serves sealed
endpoints (`supload`/`sfiles`/`sls`/`sfl`), and the app client pins that key
and seals every request. Generic browsers stay on the plaintext contract when
the host's encryption mode is off — nothing in the web platform authenticates
first-load JS over plain HTTP, so when the mode is on browsers cannot
participate at all (every plaintext route is a blind 404; see the design
doc's rejected variants).

This mirrors ADR 0002's `--url` precedent: a capability that only exists where
the Dart host runs, recorded as a documented exception instead of forcing
parity that cannot work.

## Decision

The host gains an **encryption mode** (toggle in the host view, persisted,
default on). The sealed endpoints (`POST /<token>/supload|sfiles|sls|sfl`,
envelope `'L' ‖ ephPub ‖ nonce ‖ ct+mac` in, `'L' ‖ nonce ‖ ct+mac` out;
X25519 ‖ HKDF-SHA256 ‖ ChaCha20-Poly1305), the client-side pinning, and the
key advertisement live **only in the Flutter app**
(`app/lib/src/core/crypto.dart`, `server.dart`, `client.dart`), and only while
the mode is on:

- **Mode ON** (default): the key is generated once, persisted in the
  app-support directory, and advertised in the QR (`#k=`); the server
  serves ONLY the sealed endpoints at fixed root paths (`/supload`,
  `/sfiles`, `/sls`, `/sfl`) — **no token is generated at all**, so the
  host key is the only access control. Every plaintext route (page,
  `files`, `ls`, `fl`, `upload`) answers 404, so files are neither
  readable nor writable without the key. The token/Secret-mode layer is
  deliberately not stacked on top: it always ships in the same QR as the
  key, so it adds no protection against the actual leak channel, and the
  key is strictly stronger.
- **Mode OFF**: a keyless host — no `#k=` in the QR, sealed endpoints
  closed, and the plaintext contract exactly as `landir.py`/Rust serve
  it, with Secret URL mode controlling the token path as on CLI hosts
  (the Secret URL mode toggle is hidden in the UI while encryption is
  on, since there is no token to toggle).

`landir.py` and the Rust server are unchanged in both modes: no crypto,
plaintext endpoints, QRs without `#k=`. App clients talking to a CLI host
detect the missing `#k=` and use plaintext mode with a visible "Not encrypted"
badge; a pinned server is always sealed — never a silent fallback.

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

> Update (ADR 0004): the CLI hosts (`landir.py`, Rust) later gained the same
> encryption mode behind an opt-in `--encrypt` flag — sealed endpoints, `#k=`
> fragment, blind-404 plaintext routes, byte-identical wire protocol. What
> remains app-only is the client side (pinning, sealed client). See
> [0004-cli-encrypted-mode.md](0004-cli-encrypted-mode.md).
