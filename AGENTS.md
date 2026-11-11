# AGENTS.md

## Project

File Drop Server: a single-file, zero-dependency Python HTTP server that lets any device on the LAN (e.g. an Android phone) upload files through a web page. Files land in a local uploads directory.

## Layout

- `file-drop-server.py` — the entire application (server, HTML page, upload handling, QR code encoder/renderer).
- `tests/test_file_drop_server.py` — stdlib-unittest suite (no dependencies).
- `uploads/` — default upload target, created on start. Runtime data, do not commit.

## Running

```bash
python3 file-drop-server.py [--port PORT] [--dir UPLOADS_DIR] [--secret]
# defaults: port 8000, uploads in ./uploads
```

At startup the server prints the URL to open, rendered as a scannable QR
code (ANSI half-blocks). With `--secret` the page and upload endpoint move
under a fresh random token path (`/<token>/`, `/<token>/upload`) and every
other path returns 404; the QR code encodes the full secret URL.

Python 3.7+ standard library only. No packaging, no install step, no config files. Do not introduce dependencies without an explicit request.

## Architecture

- `http.server.ThreadingHTTPServer` with a single `BaseHTTPRequestHandler` subclass.
- `GET /` serves a fixed HTML string (`PAGE`) with a drag-and-drop / file-picker UI. With `--secret`, `GET /<token>/` serves the same page (bare `/<token>` gets a 302 to add the trailing slash) and everything else 404s.
- `POST /upload` parses `multipart/form-data` manually (boundary split, `Content-Disposition` filename extraction) and writes each file to the uploads directory. With `--secret` only `POST /<token>/upload` is accepted. The page's JS posts to a relative `upload` path, so it resolves correctly under either mode.
- The QR encoder (`qr_matrix` / `qr_terminal` and helpers) is pure stdlib: byte mode, EC level M, versions 1-6, Reed-Solomon over GF(256), 8 standard masks with penalty selection, ANSI half-block rendering. Do not add a QR dependency.
- CLI args only (argparse). No env vars, no config files.

## Security rules — do not regress these

The server accepts untrusted uploads on the network. Any change must preserve:

1. Path traversal protection: every filename goes through `safe_name()` — URL-decode, backslash normalization, `os.path.basename`, control-char strip, leading-dot strip, character whitelist, then a `realpath`/`commonpath` containment check against the uploads directory. Never write a file using a client-controlled path component without this function.
2. No code execution surface: no `eval`, `exec`, `os.system`, `subprocess`, shell string interpolation, or templating of uploaded content anywhere in the codebase. Uploaded bytes are only ever written to disk.
3. The served HTML is a static constant. Do not reflect request data into it.
4. Names that resolve to existing files get a timestamp suffix instead of overwriting.

Known accepted limitations (do not "fix" silently, but flag in review): no authentication unless `--secret` is used (which gates the page and upload endpoint behind a per-run 128-bit token), no upload size limit, listens on all interfaces. LAN-only by design; it must never be exposed to the internet.

## Testing

Automated tests (stdlib `unittest`, no dependencies) — run from the repo
root before delivering changes:

```bash
python3 -m unittest discover -s tests
```

The suite covers the QR encoder (a spec-based decoder reads the matrix
back: format-info BCH check, RS syndromes via independent GF(256) math,
byte-mode round trip), `safe_name`, and the HTTP endpoints in both plain
and `--secret` modes.

Additional manual verification (also exercises real end devices):

```bash
python3 file-drop-server.py --port 8000 --dir /tmp/test-uploads &
curl -s -F "file=@somefile" http://localhost:8000/upload   # expect: OK
curl -s -F 'file=@x;filename=../../pwn' http://localhost:8000/upload  # must land inside /tmp/test-uploads as "pwn"

# with --secret (grab the token from the startup output):
curl -s -F "file=@somefile" http://localhost:8000/upload   # expect: 404
curl -s -F "file=@somefile" http://localhost:8000/<token>/upload   # expect: OK
```

Check the uploads directory after each case. Kill the server afterwards.

## Conventions

- Keep it a single file. Helpers stay module-level functions.
- Prefer small, targeted edits to `file_drop_server.py`; the HTML/CSS/JS lives in the `PAGE` string.
- Comments only where behavior is non-obvious; the code is meant to be read top to bottom.