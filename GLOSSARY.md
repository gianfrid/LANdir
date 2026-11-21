# LANdir

Glossary of project-specific terms. LANdir is a universal shared network
directory: a device hosts a small HTTP server and other devices on the same
network use it — from any web browser — to upload files (which land in a
local directory) and to download them again.

## Naming

**LANdir**:
The name, everywhere: prose, doc comments, UI strings, and code identifiers. There is no second spelling.
All-lowercase `landir` is only for names where case is a technical constraint and the ecosystem convention is lowercase — executables (`landir`, `landir.py`), Dart/library and package ids (`landir_app`), app/bundle ids (`gianfrid.landir`), container and release artifact names, platform channel names, and wire-format constants. Never mix the two spellings inside one identifier.

## Roles

**Host**:
The device running the LANdir server. Accepts uploads from clients and stores them via a `FileSink`.
_Avoid_: Server (too generic — the HTTP server is a component, not the role).

**Client**:
A device that connects to a Host to upload or download files. In the Flutter app this is the client role; a plain browser is also a client.
_Avoid_: Peer (implies symmetric roles, which LANdir is not).

## Server concepts

**Secret mode**:
The default operating mode where the page and upload endpoint live under a fresh random token path (`/<token>/`) and every other path returns 404. Disabled with `--insecure` on the desktop implementations. On the app host it applies only with encryption mode OFF — encrypted hosts are key-only and skip the token entirely (fixed root paths, ADR 0003).
_Avoid_: Auth mode, password mode (it is a capability URL, not authentication).

**FileSink**:
The storage abstraction behind which received files are written. The pure-Dart server core depends only on this interface; platform implementations (`MediaStoreFileSink` on Android, `DocumentsFileSink` on iOS) handle the actual OS storage.
_Avoid_: Upload directory (that is the desktop concept the FileSink generalizes).

**Golden vectors**:
Adversarial input/output fixtures exported from the Python reference implementation (`landir.py`) via `scripts/export_golden.py`. The Dart core tests assert byte-identical behavior against these committed JSON fixtures.
_Avoid_: Test data, fixtures (too generic).

## Networking

**Advertised URL**:
The URL clients are told to open: printed at startup and encoded in the QR code.
_Avoid_: Public URL, external URL (implies internet-facing, which LANdir is not).

**Requested port**:
The port a Host's user chose for the next start; 0 delegates the choice to the host, which picks a free dynamic-range port itself.
_Avoid_: Server port, port setting.

**Save directory**:
The directory the desktop app writes received files into; chosen with a folder picker, persisted across restarts, and null-clearable back to the default Documents directory. Only exists as a user concept on desktop — Android's and iOS's FileSinks pick their storage locations mandatorily.
_Avoid_: Upload directory (that is the CLI servers' on-disk folder; the app generalizes it behind the FileSink).

**Bound port**:
The port the process actually listens on.
_Avoid_: Server port, local port.

**Hotspot mode**:
The scenario where the Host phone runs a WiFi hotspot (Android `LocalOnlyHotspot` or iOS Personal Hotspot) and a Client connects to it. The phone is the network gateway, so its hotspot IP (e.g. `192.168.43.1` / `172.20.10.1`) is the address encoded in the QR code.
_Avoid_: Tethering (broader than what LANdir needs).

**Host key**:
The long-term X25519 identity of a Host, generated on first run, persisted in the app-support directory (never under `uploads/`), and delivered out-of-band via the QR code fragment (`#k=`). App clients pin it; pinned servers are always contacted over the sealed endpoints.
_Avoid_: Server key (the CLI hosts have no key).

**Pairing**:
The scan that binds a host address (host, port — never the per-run token) to its Host key in the client registry. A rescan presenting a different key for the same address blocks and requires explicit re-pairing.
_Avoid_: Trust, verification.
