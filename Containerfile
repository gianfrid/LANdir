# Containerfile for Landir
# Compatible with both podman and docker (docker build -f Containerfile .)
#
# Base image: python:3.12-alpine
#   - Size: ~50 MB (vs ~120 MB for -slim, ~1 GB for full)
#   - Availability: official Python image on Docker Hub, widely mirrored
#   - Performance: musl-based Alpine is lightweight; the app is pure stdlib
#     Python 3.7+, so no compilation or glibc-specific dependencies exist

FROM docker.io/library/python:3.12-alpine

# Run as an unprivileged user; uploads dir is a volume mount point
RUN addgroup -S app && adduser -S -G app app \
    && mkdir -p /app/uploads \
    && chown -R app:app /app

WORKDIR /app

COPY landir.py .

USER app

# Uploads land here; mount a host volume to persist them:
#   podman run -v ./uploads:/app/uploads -p 8000:8000 landir
VOLUME ["/app/uploads"]

EXPOSE 8000

# --port 8000 is the default; --dir /app/uploads matches the volume above
CMD ["python3", "landir.py", "--dir", "/app/uploads"]
