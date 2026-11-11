# AGENTS.md

## Project

File Drop Server: a single-file, zero-dependency Python HTTP server that lets any device on the LAN (e.g. an Android phone) upload files through a web page. Files land in a local uploads directory.

## Layout

- `file_drop_server.py` — the entire application (server, HTML page, upload handling).
- `uploads/` — default upload target, created on start. Runtime data, do not commit.

## Running

```bash
python3 file_drop_server.py [port] [uploads_dir]
# defaults: port 8000, uploads in ./uploads
```

Python 3.7+ standard library only. No packaging, no install step, no config files. Do not introduce dependencies without an explicit request.

## Architecture

- `http.server.ThreadingHTTPServer` with a single `BaseHTTPRequestHandler` subclass.
- `GET /` serves a fixed HTML string (`PAGE`) with a drag-and-drop / file-picker UI.
- `POST /upload` parses `multipart/form-data` manually (boundary split, `Content-Disposition` filename extraction) and writes each file to the uploads directory.
- CLI args only. No env vars, no config parsing.

## Security rules — do not regress these

The server accepts untrusted uploads on the network. Any change must preserve:

1. Path traversal protection: every filename goes through `safe_name()` — URL-decode, backslash normalization, `os.path.basename`, control-char strip, leading-dot strip, character whitelist, then a `realpath`/`commonpath` containment check against the uploads directory. Never write a file using a client-controlled path component without this function.
2. No code execution surface: no `eval`, `exec`, `os.system`, `subprocess`, shell string interpolation, or templating of uploaded content anywhere in the codebase. Uploaded bytes are only ever written to disk.
3. The served HTML is a static constant. Do not reflect request data into it.
4. Names that resolve to existing files get a timestamp suffix instead of overwriting.

Known accepted limitations (do not "fix" silently, but flag in review): no authentication, no upload size limit, listens on all interfaces. LAN-only by design; it must never be exposed to the internet.

## Testing

There are no automated tests. Manual verification before delivering changes:

```bash
python3 file_drop_server.py 8000 /tmp/test-uploads &
curl -s -F "file=@somefile" http://localhost:8000/upload   # expect: OK
curl -s -F 'file=@x;filename=../../pwn' http://localhost:8000/upload  # must land inside /tmp/test-uploads as "pwn"
```

Check the uploads directory after each case. Kill the server afterwards.

## Conventions

- Keep it a single file. Helpers stay module-level functions.
- Prefer small, targeted edits to `file_drop_server.py`; the HTML/CSS/JS lives in the `PAGE` string.
- Comments only where behavior is non-obvious; the code is meant to be read top to bottom.