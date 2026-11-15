# TODO / Roadmap

Open tasks and future plans.

## Android port (plan)

Decisions locked in:

- **Scope:** both roles eventually — the phone can host the drop server
  (role #1) and act as a client to any drop server, including the desktop
  one (role #2).
- **Stack:** native Kotlin.
- **Storage for received files:** `MediaStore.Downloads` (visible in the
  Files app and over USB, no storage permission needed on API 29+).

The existing Python server (`landir.py`) is the reference
oracle throughout: behavior parity, golden test vectors, and the
adversarial probe battery all come from it.

## 1. Architecture

Split into two Gradle modules so the risky logic is testable on the
desktop JVM, exactly like today's Python suite:

- **`:core` — pure Kotlin/JVM, no Android APIs.**
  - HTTP server: recommended [NanoHTTPD](https://github.com/nanohttpd/nanohttpd)
    (one small, battle-tested dependency); alternative is a raw
    `ServerSocket` port of the current Python parser for a fully
    zero-dependency option. Owner to choose before M1.
  - Routes mirrored 1:1: `/` (page), `upload` (multipart POST), `files`
    (JSON listing), `fl/<name>` (download), all living under `/<token>/`
    in secret mode, fresh token per server start.
  - Ports of `safe_name` and `download_lookup` (whitelists, basename,
    realpath containment, collision timestamp suffix).
  - Port of the QR encoder (GF(256)/Reed–Solomon, masks, penalty
    selection) — already spec-verified against libqrencode and libzbar.
  - Storage behind a tiny `FileSink` interface; the server core never
    touches Android APIs.
- **`:app` — Android shell.**
  - One activity + a foreground service that owns the server instance.
  - On-screen QR code of the reachable URL (not terminal output).
  - `MediaStoreFileSink` implementing `FileSink`.
  - Later: the client UI (role #2) on the same app.

Role #2 later reuses `:core`'s multipart writer and route knowledge —
the client is "just" another browser of the same endpoints.

## 2. Porting hazards (known from the desktop implementation)

- **Percent-decoding:** Kotlin's `URLDecoder` converts `+` → space and
  its strictness differs. Decode path segments ourselves (decode without
  `+` handling) so behavior stays traversal-equivalent; the probe
  battery must cover encoded-path differences.
- **Charsets:** request lines are Latin-1-decoded on both platforms;
  the ASCII name whitelist regex `[A-Za-z0-9._ ()\[\]-]` stays the final
  guard byte-for-byte.
- **Multipart parsing parity:** the Python parser accepts
  quoted/unquoted boundaries and strips the trailing `\r\n` framing.
  Golden byte-level fixtures from the Python side define the exact
  expected behavior; "almost right" corrupts files.
- **QR encoder:** port the logic unchanged; validate against golden
  matrices exported from the Python implementation (matrices are
  deterministic).

## 3. Milestones

### M1 — `:core` server + tests (no Android)

Routes and sanitizers feature-complete vs. the Python server;
`FileSink` faked to a JVM temp dir. Golden vectors: filename corpus,
traversal corpus, QR matrices, multipart bodies.

**Acceptance:** the adversarial probe suite passes — ideally driven by
reusing the existing Python probe script pointed at the JVM server, so
the same probes run unchanged against both implementations.

### M2 — Host app (role #1)

- Foreground service with persistent notification (Android 14+
  requires a declared FGS type: `specialUse`/`dataSync`).
- Wi-Fi IP detection (UDP-connect trick or `NetworkInterface`
  enumeration); default port 8000 or a random high port.
- On-screen QR of the URL; secret-token toggle (token in the QR and as
  a tappable URL); keep-screen-on option; start/stop button.

**Acceptance:** real device — laptop browser uploads → file appears in
Downloads; second phone scans QR → uploads and downloads; screen off
10 min → still serving (or documented OEM limitation).

### M3 — Client role (role #2)

- QR scan (CameraX + ML Kit barcode, or ZXing core).
- Server registry (remember previously used servers).
- Picker → multipart upload through `:core`'s writer.
- Browse `/files`, download manager, open-with/share intents.
- Works against the desktop Python server *and* against the app's own
  host role (self-loopback—useful for phone-to-phone without a desktop).

**Acceptance:** client talks to both the Python server and an M2 phone
host.

### M4 — Hardening, parity, release

- Re-run the full red-team battery from the security review (traversal
  variants, reflection, CRLF, malformed multipart, symlinks) plus
  MediaStore-specific cases (collision auto-rename parity, giant
  upload handling — Mobile dies on OOM, so add a configurable upload
  size cap, unlike the desktop).
- Emulator integration via `adb forward` + the Python probes.
- Self-signed release APK for sideloading; minSdk ~26 (Android 8),
  target latest.

## 4. Known risks

- **OEM background killers** (MIUI et al.) may kill even foreground
  services — notification + keep-screen-on + user education is the
  realistic mitigation; document tested devices.
- **AP client isolation** on some Wi-Fi networks blocks phone↔phone
  traffic regardless of app (same LAN caveat as the desktop version).
- **Hotspot mode** (phone AP without a router) needs
  `LocalOnlyHotspot` or manual tethering — defer to M3.5.
- **Battery:** serving forever draws power — service is user-started,
  never auto-started on boot.

## 5. Rough effort

| Milestone | Estimate |
| --- | --- |
| M1 core + test ports | 3–5 days |
| M2 host app | 4–6 days |
| M3 client role | 3–5 days |
| M4 hardening + release | 2–3 days |

Reusing the Python repo as the reference oracle (including generating
all golden files from it) is the biggest de-risking lever of the plan.

## Open decisions

1. `:core` HTTP layer: NanoHTTPD (small dep, proven) vs zero-dep raw
   `ServerSocket` port — owner's call before M1 starts.
