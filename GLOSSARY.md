# Landir

Glossary of project-specific terms. Landir is a universal shared network
directory: a device hosts a small HTTP server and other devices on the same
network use it — from any web browser — to upload files (which land in a
local directory) and to download them again.

## Naming

**LANdir**:
The user-facing product name, shown in app strings, notifications, platform launchers (Android label, iOS display name, desktop window title), and the served page's browser tab.
_Avoid_: Landir (in user-visible strings).

**Landir**:
The project name everywhere the user isn't looking: documentation, code identifiers, and package ids.
_Avoid_: LANdir (in docs, code, and identifiers).

## Roles

**Host**:
The device running the Landir server. Accepts uploads from clients and stores them via a `FileSink`.
_Avoid_: Server (too generic — the HTTP server is a component, not the role).

**Client**:
A device that connects to a Host to upload or download files. In the Flutter app this is the client role; a plain browser is also a client.
_Avoid_: Peer (implies symmetric roles, which Landir is not).

## Server concepts

**Secret mode**:
The default operating mode where the page and upload endpoint live under a fresh random token path (`/<token>/`) and every other path returns 404. Disabled with `--insecure` on the desktop implementations.
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
_Avoid_: Public URL, external URL (implies internet-facing, which Landir is not).

**Requested port**:
The port a Host's user chose for the next start; 0 delegates the choice to the host, which picks a free dynamic-range port itself.
_Avoid_: Server port, port setting.

**Bound port**:
The port the process actually listens on.
_Avoid_: Server port, local port.

**Hotspot mode**:
The scenario where the Host phone runs a WiFi hotspot (Android `LocalOnlyHotspot` or iOS Personal Hotspot) and a Client connects to it. The phone is the network gateway, so its hotspot IP (e.g. `192.168.43.1` / `172.20.10.1`) is the address encoded in the QR code.
_Avoid_: Tethering (broader than what Landir needs).
