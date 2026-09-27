#!/usr/bin/env bash
# Loads the tar.gz produced by `podman build -o type=local,dest=out -f
# Dockerfile .` (or the docker buildx equivalent) into the local image
# store. docker and podman take an identical `load -i` invocation.
set -euo pipefail
runtime=$(command -v podman || command -v docker)
exec "$runtime" load -i "${1:-out/result}"
