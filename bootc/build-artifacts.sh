#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage:
  build-artifacts.sh -i IMAGE [-t TYPE]... [-c CONFIG] [-o OUTPUT_DIR] [-r ROOTFS] [-a TARGET_ARCH]

Examples:
  ./bootc/build-artifacts.sh -i localhost/ha-san-storage:latest -t qcow2 -c bootc/configs/qcow2-user.example.toml
  ./bootc/build-artifacts.sh -i localhost/ha-san-storage:latest -t bootc-installer -c bootc/configs/storage-a-installer.example.toml

Notes:
  - TYPE may be repeated: qcow2, raw, bootc-installer, vmdk, ami, etc.
  - CONFIG is a bootc-image-builder TOML/JSON config file mounted at /config.toml.
  - For installer ISOs with custom kickstart, put user creation inside the kickstart content.
EOF
}

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -- "${SCRIPT_DIR}/.." && pwd)"
CONTAINER_TOOL="${CONTAINER_TOOL:-podman}"
BUILDER_IMAGE="${BUILDER_IMAGE:-quay.io/centos-bootc/bootc-image-builder:latest}"
OUTPUT_DIR="${SCRIPT_DIR}/output"
IMAGE=""
CONFIG=""
ROOTFS=""
TARGET_ARCH=""
TYPES=()

while getopts ":i:t:c:o:r:a:h" opt; do
  case "${opt}" in
    i) IMAGE="${OPTARG}" ;;
    t) TYPES+=("${OPTARG}") ;;
    c) CONFIG="${OPTARG}" ;;
    o) OUTPUT_DIR="${OPTARG}" ;;
    r) ROOTFS="${OPTARG}" ;;
    a) TARGET_ARCH="${OPTARG}" ;;
    h)
      usage
      exit 0
      ;;
    :) 
      echo "Missing argument for -${OPTARG}" >&2
      usage >&2
      exit 2
      ;;
    \?)
      echo "Unknown option: -${OPTARG}" >&2
      usage >&2
      exit 2
      ;;
  esac
done

if [ -z "${IMAGE}" ]; then
  echo "An image reference is required." >&2
  usage >&2
  exit 2
fi

if [ "${#TYPES[@]}" -eq 0 ]; then
  TYPES=(qcow2)
fi

mkdir -p "${OUTPUT_DIR}"
OUTPUT_DIR="$(cd -- "${OUTPUT_DIR}" && pwd)"

run_args=(
  run --rm --privileged --pull=newer
  --security-opt label=type:unconfined_t
  -v "${OUTPUT_DIR}:/output"
  -v /var/lib/containers/storage:/var/lib/containers/storage
)

if [ -n "${CONFIG}" ]; then
  if [ -f "${CONFIG}" ]; then
    CONFIG_ABS="$(cd -- "$(dirname -- "${CONFIG}")" && pwd)/$(basename -- "${CONFIG}")"
  elif [ -f "${REPO_ROOT}/${CONFIG}" ]; then
    CONFIG_ABS="$(cd -- "${REPO_ROOT}/$(dirname -- "${CONFIG}")" && pwd)/$(basename -- "${CONFIG}")"
  else
    echo "Config file not found: ${CONFIG}" >&2
    exit 2
  fi
  run_args+=( -v "${CONFIG_ABS}:/config.toml:ro" )
fi

run_args+=( "${BUILDER_IMAGE}" )

for t in "${TYPES[@]}"; do
  run_args+=( --type "${t}" )
done

if [ -n "${ROOTFS}" ]; then
  run_args+=( --rootfs "${ROOTFS}" )
fi

if [ -n "${TARGET_ARCH}" ]; then
  run_args+=( --target-arch "${TARGET_ARCH}" )
fi

run_args+=( --use-librepo=True "${IMAGE}" )

"${CONTAINER_TOOL}" "${run_args[@]}"

echo "Artifacts written to ${OUTPUT_DIR}"
