# 001 — QR-paired app encryption (deferred design)

Status: **implemented** (milestones M1–M6, branch `feat/qr-paired-encryption`).
Direction fixed (see "Decisions already made"). ADR 0003 records the parity
exception; GLOSSARY has the Host key / Pairing terms. Companion research and its source
citations: [docs/research/001-encryption-over-http-without-tls.md](../research/001-encryption-over-http-without-tls.md)
(numbered `[n]` references below point into that file's Sources list).

## Scope decisions already made (session 2026-11-18)

1. **The QR code is the key-exchange channel.** Landir's QR is a genuine
   out-of-band channel (the host's own screen); it will carry the host's
   long-term public key, giving day-one authenticated key exchange with no
   TOFU window — the CurveCP/WireGuard shape, where an active MITM degrades
   to denial of service [6][8].
2. **Encryption ships for app clients only.** Generic browsers stay on the
   plaintext HTTP contract. This is structural, not a compromise: nothing in
   the web platform authenticates first-load JS over plain HTTP (SRI §5.1
   kills its own mechanism on insecure contexts [21]; WebCrypto's own
   security considerations push the fix to TLS [18][19][20][21]).
3. The browser TLS question (self-signed cert, optionally with auth
   material embedded in it) was analyzed and **rejected as default**;
   see "Browser variants considered and rejected".

## Architecture

HOST (Dart core; pure Dart throughout, no new platform channels):

- First run generates an X25519 static keypair (**host key**), persisted in
  the app-support directory — never under `uploads/`. The host stores and
  serves plaintext by design; encryption here is transport confidentiality
  against the network, not at-rest secrecy.
- The advertised URL (QR + foreground display) gains a fragment:
  `http://ip:port/<token>/#k=<base64url(pubkey)>`. The fragment never
  crosses the wire [25]; generic camera-scan browsers ignore it; capacity is
  fine (~92 bytes fits the v1–6 / EC-M encoder, v6 byte mode = 106 B).
  The URL builder must validate total length on `--url`-style remaps and
  refuse (warn) rather than truncate key material.
- New sealed endpoints under `/<token>/` (upload / download / listing):
  decrypt first, then hand the plaintext to the EXISTING handlers — the
  decrypted filename still goes through `safeName()`, the body through the
  existing multipart parser. SPEC.md's four security rules are untouched:
  nothing reflected, static PAGE, timestamp suffix, containment all
  operate below the crypto layer.

CLIENT (Flutter app):

- The scanner parses `#k=`; `SavedServer` gains `hostKey`, persisted in the
  same shared_preferences registry. Pin to (host, port → host key), never
  to the per-run token.
- A pinned server is **always sealed — never a silent fallback** and never a
  network-negotiated mode (Noise §14 rollback discipline [7]; the framing
  decision happened at scan time, off-network, so there is nothing on the
  wire for a MITM to strip).
- Envelope, Noise-N one-way shape [7], fixed ciphersuite, no agility:
  client ephemeral X25519 ‖ HKDF-SHA256 ‖ AEAD (ChaCha20-Poly1305 or
  AES-GCM), fresh nonce per record. Per-request sealing (sealed-box
  style); listing sealed too, or filenames leak to passive observers.
- Keyless server (a landir.py / Rust host — their QR carries no `#k=`):
  plaintext mode with a visible "Not encrypted" badge.
- A rescan presenting a different key: block + explicit re-pair, the
  Signal safety-number pattern [13][14].

PARITY: the sealed endpoints and the app-binary crypto are a Dart-host-only
documented exception (the `--url` precedent, SPEC.md; record as ADR 0003 at
implementation time). CLI hosts keep plaintext + token, unchanged urls and
QRs.

## Browser variants considered and rejected

| Variant | Verdict | Why |
|---|---|---|
| Self-signed + click-through | rejected | The interstitial is human-TOFU that trains click-through; a first-use MITM presents its own self-signed cert, the user accepts it, the attacker serves the page. After acceptance the origin only becomes a secure context — this upgrades the passive rung at best (research §6) [19][20][21] |
| Self-signed + SHA-256 fingerprint embedded in the QR ("custom auth inside the cert") | rejected as default | Theoretically genuine OOB verification; practically the comparison UX is a buried certificate viewer, and Android Chrome — the primary LAN client browser — has no certificate viewer at all |
| PAKE over a QR-embedded secret | rejected | The QR carries 128+ bits nobody types; there is no low-entropy-secret problem for PAKE to solve. Dominated by the pinned-pubkey design (research §7 table) |
| Network-negotiated crypto on the browser path | rejected | Whoever controls the wire controls the negotiation outcome; SRI §5.1 pattern [21], Noise §14 rollback [7] |

The real browser upgrade remains the reverse-proxy TLS deployment already
documented in the README: with TLS the origin becomes a secure context,
restoring WebCrypto and making SRI meaningful [19][20][21].

Threat ladder once implemented: passive LAN observer → stopped (app);
active first-use MITM → app stopped (DoS at worst), browser loses
(documented); QR-holder/host insider → unchanged by design.

## Implementation milestones (when resumed, run order)

```
M1 Host key: generate/persist/load; QR/URL builder with #k=; length
   validation on remapped origins. Tests: key store round-trip, URL build.
M2 Sealed endpoints in the Dart core (upload, download, listing) with
   decrypt-then-delegate into existing handlers.
   Tests: RFC 7748 X25519 vectors, RFC 5869 HKDF vectors, golden sealed
   envelopes (committed fixtures), AEAD-failure → 400, traversal inside
   a sealed body still lands in uploads dir (SPEC rule 1 unchanged).
M3 Client pining: scan parses #k=, SavedServer.hostKey, registry
   versioning; never-seal-fallback state machine. Tests: pin round-trip,
   keyless-host badge state, rescan-changed-key blocking.
M4 Sealed transport in LandirClient (pure Dart): upload/download/listing
   envelopes; integration test app-client ↔ Dart-host over loopback.
M5 UX: badge, rescan warning, pairing copy. Widget tests.
M6 Docs: ADR 0003 (parity exception), GLOSSARY terms, README security
   note ("app = secure path; browser = documented plaintext"), SPEC.md
   gains no new rules (sealed bodies flow through the existing ones).
```

Candidate dependency: a pure-Dart crypto package (e.g. `cryptography`) —
zero platform channels; keep `client.dart`/`server.dart` Flutter-free as
today. Vendors come from RFC test vectors, not from golden exports
(the Python reference has no crypto to export — this is the documented
exception, hence ADR 0003).

Proposed GLOSSARY terms (add at M6, not before — nothing decided exists
in code until then): **Host key** (the long-term X25519 identity of a
host, delivered out-of-band via the QR; avoid "server key"); **Pairing**
(the scan that binds a host address to its host key; avoid "trust",
"verification").

## Known residuals (accepted)

- A photographed/shared QR is capability theft, same as today.
- The app binary becomes a trust root; the release APK signing story
  (currently debug-signed in CI) matters more once this ships.
- DoS is always available to a LAN attacker; encryption never fixes it.
- The 128-bit token remains visible in request paths; with sealed bodies a
  passive observer learns traffic exists, AEAD rejects garbage replays.
