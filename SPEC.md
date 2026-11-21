# Specification

## Security Rules — Do Not Regress

The server accepts untrusted uploads on the network. Any change must preserve:

1. **Path traversal protection**: every uploaded filename goes through `safe_name()` — URL-decode, backslash normalization, `os.path.basename`, control-char strip, leading-dot strip, character whitelist, then a `realpath`/`commonpath` containment check against the uploads directory. Never write a file using a client-controlled path component without this function. Every client-requested download name goes through `download_lookup()`, which applies the same whitelist and containment and only resolves regular files inside the uploads directory.
2. **No code execution surface**: no `eval`, `exec`, `os.system`, `subprocess`, shell string interpolation, or templating of uploaded content anywhere in the codebase. Uploaded bytes are only ever written to disk.
3. **The served HTML is a static constant**. Do not reflect request data into it.
4. **Names that resolve to existing files get a timestamp suffix instead of overwriting**.

Known accepted limitations (do not "fix" silently, but flag in review): secret mode (a per-run 128-bit token gating the page and upload endpoint) is ON by default and only disabled with `--insecure`; there is no upload size limit; the server listens on all interfaces. LAN-only by design; it must never be exposed to the internet.

## Testing

Automated tests — run from the repo root before delivering changes:

```bash
python3 -m unittest discover -s tests   # Python implementation
cargo test                               # Rust implementation
cargo audit                              # RustSec advisory scan of Cargo.lock
cargo sbom > SBOM.spdx.json              # regenerate the SPDX SBOM after dep changes
```

Both suites cover the QR encoder, `safe_name` and `download_lookup`, and the HTTP endpoints (upload, JSON listing, downloads, traversal rejection) in both secret (default) and `--insecure` modes. The Python QR tests use a spec-based decoder (format-info BCH check, RS syndromes via independent GF(256) math, byte-mode round trip); the Rust endpoint tests drive the axum router in-process via `tower::oneshot`, no sockets needed.

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
  - **Documented exception: sealed endpoints + host key (encryption mode).** Only the Flutter app has them: sealed POST endpoints at fixed root paths (`supload`/`sfiles`/`sls`/`sfl`), X25519 host key in the QR `#k=` fragment, client pinning — all gated behind the host's **encryption mode** toggle (persisted, default on). Mode ON: key-only — no token is generated (Secret mode is inert), only sealed endpoints answer, every plaintext route (page included) is a blind 404, so files are not readable or writable without the key. Mode OFF: a keyless host that serves the exact plaintext contract of `landir.py`/Rust, with Secret URL mode controlling the token path as usual. Generic browsers have no sealed equivalent: nothing in the web platform authenticates first-load JS over plain HTTP. Do not add crypto to `landir.py` or the Rust host — see `docs/adr/0003-sealed-app-endpoints.md` and `docs/design/001-qr-paired-app-encryption.md`. The four security rules above are unchanged below the crypto layer (decrypted bodies flow through the existing handlers).
- Prefer small, targeted edits.
- Comments only where behavior is non-obvious; the code is meant to be read top to bottom.

## See Also

- [README.md](README.md) — Project overview and running instructions
- [ARCHITECTURE.md](ARCHITECTURE.md) — Technical architecture details
