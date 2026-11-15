# Landir

A single-file, zero-dependency Python HTTP server that lets any device on the LAN (e.g. an Android phone) upload files through a web page. Files land in a local uploads directory.

> **Warning: LAN-only tool.** The server has no authentication by default (use `--secret`) and no upload size limit. Never expose it to the internet — bind it to your local network only.

## Layout

- `landir.py` — single-file, zero-dependency Python application (server, HTML page, upload handling, QR code encoder/renderer). Reference implementation; must run on a bare python3.
- `src/` + `Cargo.toml` — Rust implementation (axum/tokio). Same CLI and endpoints; distributed as a container image, so crates are fine here.
- `tests/test_landir.py` — stdlib-unittest suite for the Python version (no dependencies).
- `uploads/` — default upload target, created on start. Runtime data, do not commit.

## Running

```bash
python3 landir.py [--port PORT] [--dir UPLOADS_DIR] [--secret]
# defaults: port 8000, uploads in ./uploads
```

At startup the server prints the URL to open, rendered as a scannable QR code (ANSI half-blocks). If the requested port is occupied, the server automatically falls back to a random available high port (32768-60999).

With `--secret` the page and upload endpoint move under a fresh random token path (`/<token>/`, `/<token>/upload`) and every other path returns 404; the QR code encodes the full secret URL.

Python 3.7+ standard library only. No packaging, no install step, no config files. Do not introduce dependencies without an explicit request.

## Running in a container

A `Containerfile` (podman/docker compatible) is included. Base image: `python:3.12-alpine` (~51 MB).

```bash
# build
podman build -f Containerfile -t landir .
# docker build -f Containerfile -t landir .   # also works

# run (uploads persist to ./uploads on the host; :U fixes volume ownership)
podman run --rm -p 8000:8000 -v ./uploads:/app/uploads:U landir
# open http://<host-ip>:8000/
```

## Rust build (distroless container)

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

`Containerfile.rust` builds a distroless static image (~4 MB vs ~51 MB for
the Python one; the static binary is ~1.3 MB):

```bash
podman build -f Containerfile.rust -t landir-rust .
# docker build -f Containerfile.rust -t landir-rust .   # also works

# run (runs as UID 65532; uploads persist to ./uploads on the host)
podman run --rm -p 8000:8000 -v ./uploads:/app/uploads landir-rust
# open http://<host-ip>:8000/
```

## See Also

- [ARCHITECTURE.md](ARCHITECTURE.md) — Technical architecture details
- [SPEC.md](SPEC.md) — Security rules, testing, and conventions
- [TODO.md](TODO.md) — Roadmap (Android port plan)

## License

[AGPL-3.0-or-later](LICENSE)
