#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -- "${SCRIPT_DIR}/.." && pwd)"
CONTAINER_TOOL="${CONTAINER_TOOL:-podman}"
BASE_IMAGE="${BASE_IMAGE:-quay.io/centos-bootc/centos-bootc:stream9}"
STORAGE_IMAGE="${STORAGE_IMAGE:-localhost/ha-san-storage:latest}"
QUORUM_IMAGE="${QUORUM_IMAGE:-localhost/ha-san-quorum:latest}"
ENABLE_45DRIVES="${ENABLE_45DRIVES:-1}"
PLATFORM="${PLATFORM:-}"

build_platform_args=()
if [ -n "${PLATFORM}" ]; then
  build_platform_args+=(--platform "${PLATFORM}")
fi

"${CONTAINER_TOOL}" build \
  "${build_platform_args[@]}" \
  --file "${SCRIPT_DIR}/Containerfile.storage" \
  --build-arg "BASE_IMAGE=${BASE_IMAGE}" \
  --build-arg "ENABLE_45DRIVES=${ENABLE_45DRIVES}" \
  --tag "${STORAGE_IMAGE}" \
  "${REPO_ROOT}"

"${CONTAINER_TOOL}" build \
  "${build_platform_args[@]}" \
  --file "${SCRIPT_DIR}/Containerfile.quorum" \
  --build-arg "BASE_IMAGE=${BASE_IMAGE}" \
  --tag "${QUORUM_IMAGE}" \
  "${REPO_ROOT}"

echo "Built storage image: ${STORAGE_IMAGE}"
echo "Built quorum image:  ${QUORUM_IMAGE}"
