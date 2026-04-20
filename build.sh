#!/bin/bash
#
# sqlite-fractalsql multi-arch build.
#
# Drives docker/Dockerfile to produce fractalsql.so for a single target
# architecture. Output:
#   dist/amd64/fractalsql.so
#   dist/arm64/fractalsql.so
#
# Usage:
#   ./build.sh [amd64|arm64]        # default: amd64
#
# Cross-arch builds need QEMU + binfmt_misc. In CI this is handled by
# docker/setup-qemu-action; locally:
#   docker run --privileged --rm tonistiigi/binfmt --install all

set -euo pipefail

ARCH="${1:-amd64}"
case "${ARCH}" in
    amd64|arm64) ;;
    *)
        echo "unknown arch '${ARCH}' — expected amd64 or arm64" >&2
        exit 2
        ;;
esac

DIST_DIR="${DIST_DIR:-./dist}"
DOCKERFILE="${DOCKERFILE:-docker/Dockerfile}"
PLATFORM="linux/${ARCH}"
OUT_DIR="${DIST_DIR}/${ARCH}"

mkdir -p "${OUT_DIR}"

echo "------------------------------------------"
echo "Building sqlite-fractalsql for ${PLATFORM}"
echo "  -> ${OUT_DIR}/fractalsql.so"
echo "------------------------------------------"

DOCKER_BUILDKIT=1 docker buildx build \
    --platform "${PLATFORM}" \
    --target export \
    --output "type=local,dest=${OUT_DIR}" \
    -f "${DOCKERFILE}" \
    .

echo
echo "Built artifact for ${ARCH}:"
ls -l "${OUT_DIR}"/fractalsql.so
file "${OUT_DIR}"/fractalsql.so 2>/dev/null || true
