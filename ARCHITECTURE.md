# Architecture

## Overview

Landir uses `http.server.ThreadingHTTPServer` with a single `BaseHTTPRequestHandler` subclass.

## Endpoints

- `GET /` serves a fixed HTML string (`PAGE`) with a drag-and-drop / file-picker UI and client-side rendering of the downloads list. By default (secret mode) `GET /<token>/` serves the page (bare `/<token>` gets a 302 to add the trailing slash) and everything else 404s; with `--insecure` the plain paths are served instead.
- `POST /upload` parses `multipart/form-data` manually (boundary split, `Content-Disposition` filename extraction) and writes each file to the uploads directory. In secret mode only `POST /<token>/upload` is accepted. The page's JS posts to a relative `upload` path, so it resolves correctly under either mode.
- `GET /files` returns a JSON listing of the uploads directory (newest first); `GET /fl/<name>` streams one file as an attachment. Both move under `/<token>/` in secret mode.

## QR Code Generation

The QR encoder (`qr_matrix` / `qr_terminal` and helpers) is pure stdlib: byte mode, EC level M, versions 1-6, Reed-Solomon over GF(256), 8 standard masks with penalty selection, ANSI half-block rendering. No QR dependency is used.

## Configuration

CLI args only (argparse). No env vars, no config files.

## See Also

- [README.md](README.md) — Project overview and running instructions
- [SPEC.md](SPEC.md) — Security rules, testing, and conventions
