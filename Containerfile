# Containerfile for Landir (default: the Rust implementation, distroless static image).
# Multi-stage build: pinned rust:1.88-alpine compiles a fully static musl binary;
# Compatible with both podman and docker (docker build -f Containerfile .)
#
# Build stage: Alpine's rustc targets musl natively, so a --release build there
# is a fully static binary that needs no libc at all. The builder image is
# pinned for reproducibility; Cargo.lock pins the crate versions.

FROM docker.io/library/rust:1.99-alpine AS build
ARG TARGETARCH
RUN apk add --no-cache musl-dev
WORKDIR /build
COPY Cargo.toml Cargo.lock ./
COPY src ./src
RUN case "$TARGETARCH" in \
        amd64|x86_64) target=x86_64-unknown-linux-musl ;; \
        arm64|aarch64) target=aarch64-unknown-linux-musl ;; \
        *) echo "unsupported TARGETARCH: $TARGETARCH" >&2; exit 1 ;; \
    esac \
    && cargo build --release --locked --target "$target" \
    && mkdir -p /out/uploads \
    && cp "target/$target/release/landir" /out/landir

# Runtime stage: distroless static = no shell, no package manager, no libc (~2 MB).
# Runs as the unprivileged nonroot UID 65532 (same user as the -nonroot variant).
# Pinned by digest (multi-arch index). Dependabot keeps tag+digest in sync;
# manual fallback: scripts/update-distroless-digest.sh
FROM gcr.io/distroless/static-debian13:latest@sha256:1a64f46364620465ef9e9a8f5413757dfdf22695e050bbfd7303eeaf17a59383
COPY --from=build --chown=65532:65532 /out/landir /app/landir
COPY --from=build --chown=65532:65532 /out/uploads /app/uploads
WORKDIR /app
USER 65532:65532

# Uploads land here; mount a host volume to persist them:
#   podman run -v ./uploads:/app/uploads -p 8000:8000 landir-rust
VOLUME ["/app/uploads"]

EXPOSE 8000

ENTRYPOINT ["/app/landir"]
# --port 8000 is the default; --dir /app/uploads matches the volume above
CMD ["--dir", "/app/uploads"]
