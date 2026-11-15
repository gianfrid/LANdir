# AGENTS.md

This file contains project-specific instructions and guidelines for coding agents working on the Landir project.

## Documentation Structure

Project documentation has been split into separate files following best practices:

- **[README.md](README.md)** — Project overview, layout, and running instructions (user-facing documentation)
- **[ARCHITECTURE.md](ARCHITECTURE.md)** — Technical architecture details and design decisions
- **[SPEC.md](SPEC.md)** — Security rules, testing procedures, and conventions

## Quick Reference

For complete project context, agents should read all three files. The key points are:

### From README.md
- Python implementation: single-file, zero-dependency (`landir.py`), the reference
- Rust implementation: Cargo project (`src/`), distributed as a distroless container image
- Default: port 8000, uploads in `./uploads/`
- Use `--secret` for token-gated access

### From ARCHITECTURE.md  
- Python: `http.server.ThreadingHTTPServer` with custom request handler
- Rust: axum/tokio router (`src/server.rs`), testable without sockets via `tower::oneshot`
- Endpoints (both): `/`, `/upload`, `/files`, `/ls/<path>`, `/fl/<name>` (all under `/<token>/` with `--secret`)
- QR code: byte mode, EC level M, versions 1-6, ANSI half-block rendering
- CLI-only configuration (argparse / clap)

### From SPEC.md
**Security rules (do not regress):**
1. Path traversal protection via `safe_name()` and `download_lookup()`
2. No code execution: no eval, exec, os.system, subprocess, or templating of uploaded content
3. Static HTML constant (no request data reflection)
4. Timestamp suffix for existing files (no overwrites)

**Testing:**
- Python: `python3 -m unittest discover -s tests`
- Rust: `cargo test`
- Both cover: QR encoder, safe_name, download_lookup, HTTP endpoints, traversal rejection
- Manual verification with curl commands provided

**Conventions:**
- The single-file, stdlib-only, zero-dependency rule applies to `landir.py` ONLY
  (it is meant to run anywhere with a bare python3). The Rust implementation is a
  normal Cargo project and IS distributed as a container image, so crates and
  multiple files are fine there.
- Small, targeted edits preferred
- Comments only where behavior is non-obvious

## Agent Guidelines

- Always preserve the security rules listed in SPEC.md — they bind BOTH implementations
- Python 3.7+ standard library only (landir.py); the Rust side uses crates (Cargo.lock pinned)
- Run both test suites before delivering changes: `python3 -m unittest discover -s tests` and `cargo test`

## See Also

- [README.md](README.md)
- [ARCHITECTURE.md](ARCHITECTURE.md)
- [SPEC.md](SPEC.md)
- [TODO.md](TODO.md) — Open tasks and roadmap
