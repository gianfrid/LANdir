# `--url` overrides the advertised origin, and fails fast on a busy port

A container cannot discover the host port it was published on: the mapping
lives in the host's network namespace, and podman does not inject it into the
container's environment. With `podman run -p 18080:8000` the process binds
8000 and, without help, prints and encodes `http://<lan-ip>:8000/<token>/` —
a URL that is unreachable on the host (or, worse, reaches an unrelated
service that answers 404). The Rust implementation therefore takes
`--url http://<host>:<port>`: a full origin that replaces the scheme, host and
port in the advertised URL, while the token path is still appended. When
`--url` is set, an occupied port is a fatal error instead of the usual
fallback to a random high port, because the mapping is fixed and a fallback
would print a URL that cannot work.

## Considered options

- **Auto-detect the mapped port.** Not possible from inside the container:
  the mapped port is not visible in `/proc/net`, and podman does not export
  it. Any heuristic would silently produce wrong URLs.
- **`--public-port` (port only).** Shorter for the common case, but adds a
  second flag and cannot express `https` or a reverse proxy.
- **A path prefix in `--url`.** Rejected for now: routing is on `/<token>/`,
  so a prefix would need real routing changes. Accepting a prefix and
  ignoring it would be worse than refusing it, so a path is a validation
  error.

## Consequences

- **Only the Rust implementation has `--url`.** This is a deliberate
  exception to the cross-implementation parity rule in SPEC.md: the flag is
  meaningless outside a container, and the container ships the Rust binary.
- **A container run without `--url` keeps the old, broken behavior.** The
  flag is opt-in; the README container section tells users to pass it
  whenever they map a port.
- **The CI smoke test asserts the mapped port appears in the advertised URL**,
  and curls it, since that is the only place the bug is observable
  end-to-end.
