#!/usr/bin/env bash
# Install LANdir by pulling the prebuilt distroless container image from the
# GitHub Container Registry (public, no login needed). Nothing is compiled
# and no files are copied onto the host — the image is the install.
#
# usage: scripts/install-container.sh [--tag TAG] [--runtime podman|docker] [--no-pull]
#
#   --tag TAG        image tag to pull (default: latest; also: rolling, arm64)
#   --runtime R      container runtime to use (default: first of podman, docker)
#   --no-pull        skip the pull, just print the run command
#
# after install, run the host with:
#   podman run --rm -it -p 8000:8000 -v ./uploads:/app/uploads \
#     ghcr.io/gianfrid/landir:latest
set -euo pipefail

IMAGE=ghcr.io/gianfrid/landir
TAG=latest
RUNTIME=
DO_PULL=1

while [ $# -gt 0 ]; do
  case "$1" in
    --tag)     TAG=${2:?--tag needs a value}; shift 2 ;;
    --runtime) RUNTIME=${2:?--runtime needs a value}; shift 2 ;;
    --no-pull) DO_PULL=0; shift ;;
    -h|--help)
      sed -n '2,15p' "$0"; exit 0 ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done

if [ -z "$RUNTIME" ]; then
  for candidate in podman docker; do
    if command -v "$candidate" >/dev/null 2>&1; then RUNTIME=$candidate; break; fi
  done
else
  command -v "$RUNTIME" >/dev/null 2>&1 || {
    echo "runtime not found on PATH: $RUNTIME" >&2
    exit 1
  }
fi
[ -n "$RUNTIME" ] || {
  echo "no container runtime found — install podman or docker first:" >&2
  echo "  sudo apt install podman   # or: sudo dnf install podman" >&2
  exit 1
}

FULL_IMAGE="$IMAGE:$TAG"

if [ "$DO_PULL" -eq 1 ]; then
  echo "pulling $FULL_IMAGE with $RUNTIME ..."
  "$RUNTIME" pull "$FULL_IMAGE"
fi

echo
echo "installed $FULL_IMAGE"
echo
echo "run the host with:"
echo "  $RUNTIME run --rm -it -p 8000:8000 -v ./uploads:/app/uploads $FULL_IMAGE"
echo
echo "then open the printed URL (or scan the QR code) from any device on the LAN."
echo "see README.md for --url when publishing on a different host port."
