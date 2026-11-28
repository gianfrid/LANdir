# Specification

## Security Rules — Do Not Regress

The server accepts untrusted uploads on the network. Any change must preserve:

1. **Path traversal protection**: every uploaded filename goes through `safe_name()` — URL-decode, backslash normalization, `os.path.basename`, control-char strip, leading-dot strip, character whitelist, then a `realpath`/`commonpath` containment check against the uploads directory. Never write a file using a client-controlled path component without this function. Every client-requested download name goes through `download_lookup()`, which applies the same whitelist and containment and only resolves regular files inside the uploads directory.
2. **No code execution surface**: no `eval`, `exec`, `os.system`, `subprocess`, shell string interpolation, or templating of uploaded content anywhere in the codebase. Uploaded bytes are only ever written to disk.
3. **The served HTML is a static constant**. Do not reflect request data into it.
4. **Names that resolve to existing files get a unique timestamp suffix instead of overwriting** — the suffix is re-rolled (counter/microseconds) until the candidate does not exist, and publication is exclusive: the body is staged in a hidden dot-prefixed temp file created with `O_EXCL` / `create_new` and only then atomically linked under the final name. Concurrent same-name uploads can therefore never overwrite or interleave into each other, and a file never becomes visible (listable, downloadable) before it is fully written. Hidden dot-prefixed names are never listed or served. A server-side save failure (disk full, uploads dir gone) must surface as a 500 with an event naming the failure — never as a client-error 400.

Known accepted limitations (do not "fix" silently, but flag in review): secret mode (a per-run 128-bit token gating the page and upload endpoint) is ON by default and only disabled with `--insecure`; uploads are unlimited by default — `--max-upload BYTES` bounds per-request size with a pre-read 413 (the request body is buffered in memory, so the cap is what bounds the memory an upload can cost; it does not bound total disk usage); the server listens on all interfaces. LAN-only by design; it must never be exposed to the internet.

## Testing

Automated tests — run from the repo root before delivering changes:

```bash
python3 -m unittest discover -s tests   # Python implementation
cargo test                               # Rust implementation
cargo audit                              # RustSec advisory scan of Cargo.lock
cargo sbom > SBOM.spdx.json              # regenerate the SPDX SBOM after dep changes
```

Both suites cover the QR encoder, `safe_name` and `download_lookup`, and the HTTP endpoints (upload, JSON listing, downloads, traversal rejection) in secret (default), `--insecure`, and `--encrypt` modes. The encrypted-mode tests cover the sealed endpoints end-to-end (upload/list/download round trip, traversal inside a sealed body still contained, AEAD failure → 400, plaintext routes → blind 404) plus RFC 7748/5869/8439 vectors and a golden sealed-envelope fixture generated from `landir.py` and asserted byte-identical by the Rust suite. The Python QR tests use a spec-based decoder (format-info BCH check, RS syndromes via independent GF(256) math, byte-mode round trip); the Rust endpoint tests drive the axum router in-process via `tower::oneshot`, no sockets needed.

### Manual Verification

Additional manual verification (also exercises real end devices):

```bash
python3 landir.py --port 8000 --dir /tmp/test-uploads &
curl -s -F "file=@somefile" http://localhost:8000/upload   # expect: OK
curl -s -F 'file=@x;filename=../../pwn' http://localhost:8000/upload  # must land inside /tmp/test-uploads as "pwn"

# secret mode is the default (grab the token from the startup output);
# with --insecure (-i) the plain URLs are served instead:
curl -s -F "file=@somefile" http://localhost:8000/upload   # expect: 404 (secret default)
curl -s -F "file=@somefile" http://localhost:8000/<token>/upload   # expect: OK
```

Check the uploads directory after each case. Kill the server afterwards.

## Conventions

- `landir.py` stays a single file with module-level helpers (it must run on a bare python3); the HTML/CSS/JS lives in the `PAGE` constant.
- The Rust implementation is a Cargo project under `src/` (single-file/zero-dependency does NOT apply to it; it ships as a container image).
- **Interoperability across implementations is the invariant:** the Python, Rust, and Dart hosts must preserve the security rules above and interoperate — same endpoints and on-the-wire behavior, so every device sees the same shared directory. Identical CLI flags are a means, not the objective. `landir.py` is the reference implementation — a behavior change is made there first (with a test), then ported (with an equivalent test).
  - **Documented exception: `--url`.** Only the Rust implementation has it. It exists to correct the advertised URL when a port mapping sits between the process and the client, which only happens for the container image (which ships the Rust binary). Do not "restore parity" by adding it to `landir.py` or the app — see `docs/adr/0002-advertised-url-override.md`.
  - **Encryption mode (sealed endpoints + host key) is on every host**, gated differently per host: the Flutter app has a persisted toggle (default on); the CLI hosts (`landir.py`, Rust) have an opt-in `--encrypt` flag (default off, so the browser flow keeps working out of the box — see `docs/adr/0004-cli-encrypted-mode.md`). Mode ON everywhere: sealed POST endpoints at fixed root paths (`supload`/`sfiles`/`sls`/`sfl`), X25519 host key in the QR `#k=` fragment, key-only — no token is generated (Secret mode is inert), only sealed endpoints answer, every plaintext route (page included) is a blind 404, so files are not readable or writable without the key. The wire protocol is identical on all hosts (X25519 ‖ HKDF-SHA256 ‖ ChaCha20-Poly1305, envelopes `'L' ‖ …`; golden fixtures are asserted by both the Python and Rust suites — see `docs/adr/0003-sealed-app-endpoints.md` and `docs/design/001-qr-paired-app-encryption.md`). Client-side pinning remains app-only. Generic browsers have no sealed equivalent: nothing in the web platform authenticates first-load JS over plain HTTP, so an encrypted host is only reachable with a LANdir app client — the host's startup output says so explicitly. The four security rules above are unchanged below the crypto layer (decrypted bodies flow through the existing handlers).
- Prefer small, targeted edits.
- Comments only where behavior is non-obvious; the code is meant to be read top to bottom.

## See Also

- [README.md](README.md) — Project overview and running instructions
- [ARCHITECTURE.md](ARCHITECTURE.md) — Technical architecture details
