#!/usr/bin/env bash
set -euo pipefail

KEY_URL="https://repo.45drives.com/key/gpg.asc"
KEY_PATH="/etc/pki/rpm-gpg/RPM-GPG-KEY-45drives"
REPO_PATH="/etc/yum.repos.d/45drives.repo"
EXPECTED_FP="3FBD7E034E80BAF63D5AA9BB98899BBC7318C72B"
TMP_KEY="$(mktemp)"
cleanup() {
  rm -f "${TMP_KEY}"
}
trap cleanup EXIT

curl -fsSL "${KEY_URL}" -o "${TMP_KEY}"
FINGERPRINT="$(gpg --with-fingerprint --with-colons "${TMP_KEY}" 2>/dev/null | awk -F: '$1 == "fpr" {print toupper($10); exit}')"
if [ "${FINGERPRINT}" != "${EXPECTED_FP}" ]; then
  echo "45Drives GPG fingerprint mismatch: expected ${EXPECTED_FP}, got ${FINGERPRINT}" >&2
  exit 1
fi

install -D -m 0644 "${TMP_KEY}" "${KEY_PATH}"
rpm --import "${KEY_PATH}"
cat >"${REPO_PATH}" <<'EOF'
[45drives]
name=45Drives Repository
baseurl=https://repo.45drives.com/rockylinux/el9
enabled=1
gpgcheck=1
gpgkey=file:///etc/pki/rpm-gpg/RPM-GPG-KEY-45drives
EOF

dnf -y install \
  cockpit-file-sharing \
  cockpit-identities \
  cockpit-navigator \
  cockpit-zfs \
  cockpit-scheduler
