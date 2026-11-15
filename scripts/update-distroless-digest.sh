#!/usr/bin/env bash
# Update the pinned digest of the distroless base image in the Containerfile.
#
# Resolves the current index (manifest list) digest of the :latest tag via
# podman and rewrites the FROM line. Run from the repo root:
#
#     ./scripts/update-distroless-digest.sh
#
# Requires: podman. Exits non-zero if the digest cannot be resolved.

set -euo pipefail

IMAGE="gcr.io/distroless/static-debian13"
TAG="latest"
CONTAINERFILE="${1:-Containerfile}"

cd "$(dirname "$0")/.."

old=$(grep -oE "${IMAGE}(:${TAG})?@sha256:[a-f0-9]+" "$CONTAINERFILE" | head -1 || true)

# Pull the tag and read back the repository (index) digest podman recorded.
podman pull --quiet "${IMAGE}:${TAG}" >/dev/null
new=$(podman images --format '{{.Digest}}' "${IMAGE}:${TAG}" | head -1)

if ! [[ "$new" =~ ^sha256:[a-f0-9]{64}$ ]]; then
    echo "error: could not resolve digest for ${IMAGE}:${TAG} (got: ${new:-none})" >&2
    exit 1
fi

ref="${IMAGE}:${TAG}@${new}"
if [[ "$old" == "$ref" ]]; then
    echo "up to date: ${ref}"
    exit 0
fi

sed -i -E "s|${IMAGE}(:${TAG})?@sha256:[a-f0-9]+|${ref}|" "$CONTAINERFILE"
echo "updated ${CONTAINERFILE}:"
echo "  old: ${old:-<none>}"
echo "  new: ${ref}"
