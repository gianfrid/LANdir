# AGENTS.md

This file contains project-specific instructions and guidelines for coding agents working on the LANdir project.

## Documentation Structure

Project documentation has been split into separate files following best practices:

- **[README.md](README.md)** — Project overview, layout, and running instructions (user-facing documentation)
- **[ARCHITECTURE.md](ARCHITECTURE.md)** — Technical architecture details and design decisions
- **[SPEC.md](SPEC.md)** — Security rules, testing procedures, and conventions

For complete project context, read README.md, ARCHITECTURE.md, and SPEC.md.

## Agent Guidelines

- Always preserve the security rules listed in SPEC.md — they bind BOTH implementations
- Keep `landir.py` and the Rust implementation (`src/`) interoperable: same endpoints and behavior — the aim is interoperability, not identical flags. `landir.py` is the reference — change it first with a test, then port to Rust with an equivalent test. Documented exception: `--url` is Rust-only (it corrects the advertised URL behind a container port mapping, which never applies to the others) — see SPEC.md and `docs/adr/0002-advertised-url-override.md`; do not "restore parity" by adding it elsewhere
- Python 3.7+ standard library only (landir.py); the Rust side uses crates (Cargo.lock pinned)
- Run both test suites before delivering changes: `python3 -m unittest discover -s tests` and `cargo test`

## See Also

- [README.md](README.md)
- [ARCHITECTURE.md](ARCHITECTURE.md)
- [SPEC.md](SPEC.md)
