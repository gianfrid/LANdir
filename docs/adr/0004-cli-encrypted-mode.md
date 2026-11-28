# Encrypted mode (sealed endpoints + host key) on the CLI hosts

Status: accepted

## Context

ADR 0003 made the sealed endpoints, the QR `#k=` host-key fragment, and
client pinning a Flutter-app-only parity exception: `landir.py` and the Rust
server were documented as plaintext + token only, on the grounds that a CLI
host's primary client is a browser, and browsers cannot participate in the
sealed protocol (nothing in the web platform authenticates first-load JS over
plain HTTP — see
[docs/design/001-qr-paired-app-encryption.md](../design/001-qr-paired-app-encryption.md)).

The requirement changed: CLI hosts should also be able to run encrypted mode
for clients that are the LANdir app (e.g. a desktop/server host used only
with the app, where a passive LAN observer must not read filenames or file
contents).

## Decision

`landir.py` and the Rust implementation gain an **opt-in `--encrypt` flag**
(mutually exclusive with `--insecure`). When set, the host behaves exactly
like the app host in encryption mode (ADR 0003):

- A long-term X25519 **host key** is generated on first run and persisted
  outside `uploads/` (never served): `$LANDIR_KEY_DIR`, else
  `$XDG_CONFIG_HOME/landir`, else `~/.config/landir`, else a `.landir/`
  directory next to the uploads dir (the fallback covers containers running
  without `HOME`). The file is `host_key.bin`, mode 0600, holding the 32-byte
  seed; a corrupt file is regenerated.
- **No token is generated** (Secret mode is inert): the sealed endpoints
  answer at the fixed root paths `POST /supload`, `/sfiles`, `/sls`, `/sfl`
  and every plaintext route (page included) is a blind 404.
- The advertised URL carries the key in the fragment:
  `http://ip:port/#k=<base64url(pubkey)>`, encoded in the QR code. If the URL
  would exceed the QR capacity (106 bytes, versions 1-6, EC level M), the key
  is never truncated: the host warns and falls back to advertising the keyless
  URL — the app host's behavior (`advertisedUrlWithKey` returning null).
- The wire protocol is byte-identical to the app's
  (`app/lib/src/core/crypto.dart`): request envelope
  `'L' ‖ ephPub(32) ‖ nonce(12) ‖ ct‖mac`, response envelope
  `'L' ‖ nonce(12) ‖ ct‖mac`, X25519 ‖ HKDF-SHA256 (info
  `landir-sealed-v1-request` / `landir-sealed-v1-response`) ‖
  ChaCha20-Poly1305, fresh nonce per record, all-zero DH rejected
  (RFC 7748 §6.1). Python implements it in pure stdlib (X25519/HKDF/ChaCha20-
  Poly1305 by hand, RFC vectors in the test suite); Rust uses `x25519-dalek`,
  `hkdf`, `sha2`, `chacha20poly1305`. A golden fixture generated from
  `landir.py` with fixed seeds/nonces is asserted byte-identical by the Rust
  suite, so the two (and the app) interoperate.
- Decrypted bodies flow through the existing handlers: `safe_name` /
  `download_lookup` still apply (SPEC.md rule 1 below the crypto layer),
  sealed paths are taken verbatim (no percent-decoding), AEAD failure is a
  plain 400, save failure a plain 500 with an event.
- **Endpoint-splice hardening**: the request path is not authenticated (the
  app's envelope format has no AAD), so a path-rewriting MITM can post a
  valid sealed envelope to a different sealed endpoint. The CLI hosts enforce
  the documented per-endpoint plaintext shapes — notably `/sfiles` must
  receive an EMPTY plaintext (the design doc fixes it; the app client always
  sends one) — making the plaintexts mutually incompatible, so every
  cross-endpoint splice fails with a visible 400/404 instead of a 200. A 200
  here would be dangerous: the app client treats a sealed 200 as success, so
  a redirected upload would look saved while being dropped (or a downloaded
  "file" would actually be the listing JSON). Covered by the
  `*_endpoint_splices_rejected` tests in the Python and Rust suites and the
  equivalent splice-matrix test in `app/test/core/sealed_server_test.dart`.
  Found during review: the app's host had the same gap and got the same fix,
  and the app client additionally requires the sealed upload response
  payload to be `OK` (`client.dart`) — a redirected upload fails visibly
  even against a host that ignores the empty-plaintext rule.

**Default OFF on the CLI hosts** (unlike the app's default-on toggle): the
CLI hosts' out-of-the-box client is a browser, and with encryption on browsers
get only 404s. When `--encrypt` is active, the startup output (plain and
full-screen UI) tells the host user exactly that:

> Encryption mode ON: LANdir app required — scan the QR; browsers get 404.

(One short line in the plain log output, so it never wraps mid-sentence on a
narrow terminal; in the full-screen UI the header line is
` LANdir   [encrypted: LANdir app only — browsers get 404]   <keyless URL>   (q: QR on/off, Ctrl+C: stop)`
— the mode tag sits first so terminal-width truncation cannot cut it off, and
the keyless URL is shown there because the QR already carries the `#k=`
fragment.)

## Consequences

- The sealed endpoints and `#k=` fragment are no longer an app-only exception:
  all three hosts implement them behind their respective encryption-mode
  switches; the app-only parts are the client side (pinning, sealed client,
  "Not encrypted" badge). ADR 0003's host-side description now applies to the
  CLI hosts too; `--url` remains the only Rust-only flag.
- `landir.py` keeps its zero-dependency rule: the crypto is hand-rolled pure
  stdlib, verified against RFC 7748 / 5869 / 8439 vectors. Rust gains four
  crypto crates (Cargo.lock pinned, SBOM regenerated).
- Host-key persistence is the operator's responsibility on CLI hosts: without
  a writable key dir (or a mounted volume / `LANDIR_KEY_DIR`) the key is
  recreated per run and app clients must re-pair.
- The host key is a capability: whoever scans the QR (or reads the printed
  URL) can read and write files, same as the token today.
- `landir.py`'s pure-stdlib X25519 is not written as constant-time code (none
  is available on a bare python3). The Montgomery ladder's branch structure
  keeps the executed operation sequence key-independent, and LANdir's threat
  model is a network attacker, not a co-resident timing attacker; the Rust and
  app implementations use constant-time code (curve25519-dalek /
  package:cryptography). Same reasoning the Dart design doc records for its
  accepted residuals: replayed identical envelopes still decrypt (fresh random
  nonces make forgery impossible, but AEAD alone does not de-duplicate), and
  DoS remains available to any LAN attacker.
