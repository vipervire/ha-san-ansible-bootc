# bootc deployment guide for the HA SAN

This directory turns the mutable package-install portion of the HA SAN deployment into **bootc-derived CentOS Stream 9 images**.

It keeps a clear split between:

1. **image build time** for the host OS, kernel, repositories, and packages
2. **Ansible bootstrap time** for host configuration, clustering, services, templates, and monitoring
3. **manual operator-reviewed steps** for destructive or environment-specific storage actions

## Contents

```text
bootc/
├── Containerfile.storage
├── Containerfile.quorum
├── README.md
├── bootstrap-cluster.sh
├── build-artifacts.sh
├── build-images.sh
├── configs/
│   ├── qcow2-user.example.toml
│   ├── quorum-installer.example.toml
│   ├── storage-a-installer.example.toml
│   └── storage-b-installer.example.toml
└── files/
    ├── 00-ha-san.toml
    ├── build-zfs.sh
    ├── config.toml
    ├── install-45drives.sh
    ├── prepare-root.conf
    └── wheel-passwordless-sudo
```

## What each image contains

### `Containerfile.storage`

Used for `storage-a` and `storage-b`.

Bakes in:

- CentOS Stream 9 bootc base
- OpenZFS on EL9 with DKMS
- iSCSI initiator and target packages
- Pacemaker, Corosync, pcs, and fence agents
- NFS, Samba, Cockpit, exporters, and supporting tools
- optional 45Drives Cockpit plugins

### `Containerfile.quorum`

Used for `quorum`.

Bakes in:

- base admin and hardening packages
- Pacemaker, Corosync, pcs, and fence agents
- monitoring packages
- no ZFS or storage-service stack

## Defaults embedded in the image

The image build drops several defaults into the bootc image itself:

- `files/00-ha-san.toml` sets the installed root filesystem to `xfs`
- `files/config.toml` sets minimum sizes for `/` and `/boot`
- `files/prepare-root.conf` enables `composefs`
- `bootc-fetch-apply-updates.timer` is masked so updates do not auto-apply during cluster operations

## Prerequisites

On the build host:

- Podman
- enough disk space for the images and generated artifacts
- if SELinux is enforcing, install the OSBuild SELinux policy package required by `bootc-image-builder`

For deployment:

- static management-network details for all three nodes
- a dedicated OS install disk for each node
- access to the resulting qcow2/raw/installer artifacts
- ideally, a registry the deployed systems can reach for future `bootc upgrade`

## Build the images

### Local testing

```bash
./bootc/build-images.sh
```

This builds:

- `localhost/ha-san-storage:latest`
- `localhost/ha-san-quorum:latest`

### Production-oriented build refs

For ongoing bootc lifecycle management, use image refs that the installed systems can reach later.

```bash
export STORAGE_IMAGE=registry.example.com/ha-san/storage:stable
export QUORUM_IMAGE=registry.example.com/ha-san/quorum:stable
./bootc/build-images.sh
podman push "$STORAGE_IMAGE"
podman push "$QUORUM_IMAGE"
```

Important:

- deployed systems track an image reference for `bootc upgrade`
- `localhost/...` is useful for local artifact creation and lab work, but not as a normal remote update source for deployed hosts
- if you later want hosts to follow a different image ref, use `bootc switch`

Optional knobs:

```bash
ENABLE_45DRIVES=0 ./bootc/build-images.sh
BASE_IMAGE=quay.io/centos-bootc/centos-bootc:stream9 ./bootc/build-images.sh
PLATFORM=linux/amd64 ./bootc/build-images.sh
```

## Build deployable artifacts

### Installer ISO

Create one ISO per node so the hostname and static management IP are baked into kickstart.

```bash
./bootc/build-artifacts.sh \
  -i "${STORAGE_IMAGE:-localhost/ha-san-storage:latest}" \
  -t bootc-installer \
  -c bootc/configs/storage-a-installer.example.toml \
  -o bootc/output-storage-a-iso

./bootc/build-artifacts.sh \
  -i "${STORAGE_IMAGE:-localhost/ha-san-storage:latest}" \
  -t bootc-installer \
  -c bootc/configs/storage-b-installer.example.toml \
  -o bootc/output-storage-b-iso

./bootc/build-artifacts.sh \
  -i "${QUORUM_IMAGE:-localhost/ha-san-quorum:latest}" \
  -t bootc-installer \
  -c bootc/configs/quorum-installer.example.toml \
  -o bootc/output-quorum-iso
```

Before using the example installer configs:

- replace every `<PLACEHOLDER>` value
- point `ignoredisk --only-use=` at the dedicated OS disk
- verify the management NIC name
- generate the password hash with `openssl passwd -6`

### QCOW2 or RAW image

```bash
./bootc/build-artifacts.sh \
  -i "${STORAGE_IMAGE:-localhost/ha-san-storage:latest}" \
  -t qcow2 \
  -c bootc/configs/qcow2-user.example.toml \
  -o bootc/output-storage-qcow2

./bootc/build-artifacts.sh \
  -i "${QUORUM_IMAGE:-localhost/ha-san-quorum:latest}" \
  -t raw \
  -c bootc/configs/qcow2-user.example.toml \
  -o bootc/output-quorum-raw
```

Notes:

- the generic bootc base image does not include a default user
- `qcow2-user.example.toml` is intended for qcow2/raw builds
- the installer TOMLs already create the admin user through kickstart
- do not combine `[[customizations.user]]` with an installer kickstart in the same config

## Install the nodes

Install:

- `storage-a` from the storage image
- `storage-b` from the storage image
- `quorum` from the quorum image

After first boot, verify:

- hostname
- management IP and routing
- SSH access as `storageadmin`
- the OS was installed to the correct disk

## Bootstrap the cluster with Ansible

Once all three nodes are installed and reachable:

```bash
./bootc/bootstrap-cluster.sh --ask-vault-pass
```

This runs:

```bash
ansible-playbook -i inventory.yml site.yml -e bootc_skip_packages=true
```

That reuses the existing playbook for:

- host configuration and hardening
- iSCSI target and initiator setup
- Corosync/Pacemaker formation
- NFS, SMB, and client-facing iSCSI config
- monitoring and Cockpit setup

## What remains manual on purpose

After Ansible completes, use the generated scripts on the active storage node:

- `/root/create-pool.sh`
- `/root/configure-stonith.sh`
- `/root/configure-pacemaker-resources.sh`

These remain manual because they are destructive, environment-specific, or depend on verified runtime state.

## Update flow

For rolling maintenance on deployed bootc nodes:

1. publish or retag the next image revision
2. update `quorum`
3. update the standby storage node
4. update the active storage node

Common commands on a node:

```bash
sudo bootc upgrade --download-only
sudo bootc status --verbose
sudo bootc upgrade --from-downloaded --apply
```

Or fetch and apply immediately:

```bash
sudo bootc upgrade --apply
```

If you need to move a host to a different tracked image ref:

```bash
sudo bootc switch registry.example.com/ha-san/storage:stable
```

Rollback path:

```bash
sudo bootc rollback
sudo reboot
```

For storage nodes, always move cluster resources away first and verify the returning node is healthy before touching the peer.
