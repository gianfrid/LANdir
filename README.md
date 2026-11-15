# Landir

A single-file, zero-dependency Python HTTP server that lets any device on the LAN (e.g. an Android phone) upload files through a web page. Files land in a local uploads directory.

> **Warning: LAN-only tool.** Secret mode is on by default (random token URL); pass `--insecure` only on a trusted LAN. There is no upload size limit. Never expose it to the internet — bind it to your local network only.

## Project objectives

- **Feature parity:** `landir.py` (Python) and `src/` (Rust) must stay behaviorally identical — same CLI flags, same endpoints, same responses, same security rules. `landir.py` is the reference implementation; any behavior change lands there first (with tests), then is ported to Rust.

## Layout

- `landir.py` — single-file, zero-dependency Python application (server, HTML page, upload handling, QR code encoder/renderer). Reference implementation; must run on a bare python3.
- `src/` + `Cargo.toml` — Rust implementation (axum/tokio). Same CLI and endpoints; distributed as a container image, so crates are fine here.
- `tests/test_landir.py` — stdlib-unittest suite for the Python version (no dependencies).
- `uploads/` — default upload target, created on start. Runtime data, do not commit.

## Running

```bash
python3 landir.py [--port PORT] [--dir UPLOADS_DIR] [--insecure]
# defaults: port 8000, uploads in ./uploads, secret mode ON
```

At startup the server prints the URL to open, rendered as a scannable QR code (ANSI half-blocks). If the requested port is occupied, the server automatically falls back to a random available high port (32768-60999).

Secret mode is the default: the page and upload endpoint live under a fresh random token path (`/<token>/`, `/<token>/upload`) and every other path returns 404; the QR code encodes the full secret URL. Pass `--insecure` (`-i`) to serve on plain `/`, `/upload`, ... URLs instead.

Python 3.7+ standard library only. No packaging, no install step, no config files. Do not introduce dependencies without an explicit request.

## Running in a container

The default `Containerfile` (podman/docker compatible) builds the **Rust**
implementation as a distroless static image (~4.5 MB; static binary ~1.3 MB,
no shell/libc/package manager, runs as UID 65532):

```bash
# build
podman build -f Containerfile -t landir .
# docker build -f Containerfile -t landir .   # also works

# run (-it attaches a TTY so Ctrl+C stops the server; uploads persist to
# ./uploads on the host)
podman run --rm -it -p 8000:8000 -v ./uploads:/app/uploads landir
# open http://<host-ip>:8000/
```

## Rust build (local)

The Rust implementation (`src/`, Cargo project) is the same server — same
flags, same endpoints, same security rules — built on axum/tokio. Unlike the
Python file it is distributed as a container image, so it uses crates
(versions pinned in `Cargo.lock`).

```bash
cargo build --release   # native binary
cargo test              # unit + in-process endpoint tests (no sockets)
# static musl binary for distroless:
cargo build --release --target x86_64-unknown-linux-musl
```

## Supply chain

- `SBOM.spdx.json` — SPDX SBOM of every third-party crate (regenerate after any
  dependency change with `cargo sbom > SBOM.spdx.json`, requires `cargo install cargo-sbom`)
- `cargo audit` — vulnerability scan of `Cargo.lock` against the RustSec
  advisory database (requires `cargo install cargo-audit`); currently clean
- The container base is `gcr.io/distroless/static-debian13` pinned by
  **digest** (multi-arch index) in the `Containerfile`; on GitHub, Dependabot
  keeps tag+digest and Cargo deps updated automatically (`.github/dependabot.yml`).
  Offline fallback: `./scripts/update-distroless-digest.sh`

## CI / automation (GitHub, free for public repos)

- `.github/workflows/ci.yml` — on every push/PR: Python unittest suite, `cargo test
  --locked`, `cargo audit`, SBOM freshness check (normalized diff), and a
  container build + smoke test with podman
- `.github/dependabot.yml` — weekly updates for the `docker` (Containerfile
  FROM lines, tag+digest) and `cargo` (Cargo.lock) ecosystems

## See Also

- [ARCHITECTURE.md](ARCHITECTURE.md) — Technical architecture details
- [SPEC.md](SPEC.md) — Security rules, testing, and conventions
- [TODO.md](TODO.md) — Roadmap (Android port plan)

## License

[AGPL-3.0-or-later](LICENSE)
