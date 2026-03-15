#!/usr/bin/env bash
set -euo pipefail

if [ ! -e /lib/modules ] && [ -d /usr/lib/modules ]; then
  ln -s /usr/lib/modules /lib/modules
fi

KERNELVER="$(rpm -q --qf '%{VERSION}-%{RELEASE}.%{ARCH}\n' kernel-core | head -n1)"
DIST_SUFFIX="$(rpm --eval '%{dist}')"
ZFS_RELEASE_RPM="https://zfsonlinux.org/epel/zfs-release-3-0${DIST_SUFFIX}.noarch.rpm"

# Enable CRB before EPEL on EL9-family systems.
dnf config-manager --set-enabled crb || true

dnf -y install epel-release
dnf -y install "${ZFS_RELEASE_RPM}"
dnf -y install \
  "kernel-devel-${KERNELVER}" \
  dkms \
  gcc \
  make \
  perl \
  elfutils-libelf-devel \
  zfs \
  zfs-dkms

dkms autoinstall -k "${KERNELVER}"
depmod "${KERNELVER}"

mkdir -p /etc/modules-load.d
cat >/etc/modules-load.d/zfs.conf <<'EOF'
zfs
EOF
