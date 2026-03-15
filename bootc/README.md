# bootc-based atomic deployment for the HA SAN

This directory converts the mutable package-install portion of the Ansible deployment into **bootc-derived CentOS Stream 9 images**:

- `Containerfile.storage` builds the image used for `storage-a` and `storage-b`
- `Containerfile.quorum` builds the smaller image used for `quorum`
- `build-images.sh` builds the OCI images locally with Podman
- `build-artifacts.sh` converts those OCI images into deployable artifacts such as `qcow2`, `raw`, or `bootc-installer` ISO images
- `bootstrap-cluster.sh` reuses the existing Ansible playbook as the day-1 cluster bootstrap, with package installation disabled

## Why this layout

The original playbook mixes three kinds of work:

1. OS/package/repository setup
2. service and cluster configuration
3. environment-specific manual steps (pool creation, STONITH validation, Pacemaker resource creation)

`bootc` is a strong fit for **#1**, but #2 and #3 are still better expressed in Ansible and operator-reviewed scripts. The result is:

- image build time installs the kernel, ZFS, iSCSI, Pacemaker, Cockpit, and monitoring packages
- first deployment still uses your current inventory, variables, templates, handlers, and validation logic
- manual storage-cluster steps remain explicit and visible

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

## Prerequisites

On the build host:

- Podman
- enough local disk space for the image plus generated artifacts
- if SELinux is enforcing, install `osbuild-selinux` before using `bootc-image-builder`

On the deployment side:

- a registry or local container storage location reachable by the system building artifacts
- static management IP details for each node
- a dedicated OS boot disk that is **not** one of the SAN data disks

## Build the images

From the repository root:

```bash
./bootc/build-images.sh
```

By default this creates:

- `localhost/ha-san-storage:latest`
- `localhost/ha-san-quorum:latest`

Optional environment variables:

```bash
BASE_IMAGE=quay.io/centos-bootc/centos-bootc:stream9 \
ENABLE_45DRIVES=1 \
./bootc/build-images.sh
```

## Create deployable artifacts

### QCOW2 / RAW disk images

```bash
# Make a qcow2 image for a storage node VM
./bootc/build-artifacts.sh \
  -i localhost/ha-san-storage:latest \
  -t qcow2 \
  -c bootc/configs/qcow2-user.example.toml \
  -o bootc/output-storage-qcow2

# Make a raw image for bare metal or another pipeline
./bootc/build-artifacts.sh \
  -i localhost/ha-san-quorum:latest \
  -t raw \
  -c bootc/configs/qcow2-user.example.toml \
  -o bootc/output-quorum-raw
```

### Installer ISO

Generate one installer per node so each ISO bakes in the right hostname and management addressing.

```bash
./bootc/build-artifacts.sh \
  -i localhost/ha-san-storage:latest \
  -t bootc-installer \
  -c bootc/configs/storage-a-installer.example.toml \
  -o bootc/output-storage-a-iso

./bootc/build-artifacts.sh \
  -i localhost/ha-san-storage:latest \
  -t bootc-installer \
  -c bootc/configs/storage-b-installer.example.toml \
  -o bootc/output-storage-b-iso

./bootc/build-artifacts.sh \
  -i localhost/ha-san-quorum:latest \
  -t bootc-installer \
  -c bootc/configs/quorum-installer.example.toml \
  -o bootc/output-quorum-iso
```

Before using the example installer configs:

- replace every `<PLACEHOLDER>` value
- point `ignoredisk --only-use=` at the dedicated OS disk
- confirm the management NIC name is correct
- generate the user password hash with `openssl passwd -6`

## Install the nodes

Install the generated artifacts on:

- `storage-a` using the storage image
- `storage-b` using the storage image
- `quorum` using the quorum image

After first boot, confirm SSH access as the configured admin user.

## Run the existing cluster bootstrap

Once the nodes are installed and reachable, reuse the current playbook while skipping package installation:

```bash
./bootc/bootstrap-cluster.sh --ask-vault-pass
```

That wrapper expands to:

```bash
ansible-playbook -i inventory.yml site.yml -e bootc_skip_packages=true
```

What still happens in Ansible:

- SSH key/user setup and local policy configuration
- nftables, sysctl, PAM, watchdog, and service configuration
- iSCSI target/initiator configuration
- Corosync/Pacemaker cluster formation
- NFS/SMB/iSCSI client-facing service configuration
- monitoring exporters and timers

What still remains manual on purpose:

- `/root/create-pool.sh`
- `/root/configure-stonith.sh`
- `/root/configure-pacemaker-resources.sh`

## Update flow

Build and publish a new bootc image revision, then update one node at a time.

Suggested order:

1. move cluster resources away from the node you are updating
2. run `bootc upgrade` on that node
3. reboot the node
4. verify cluster health and storage services
5. repeat for the next node

For the active/passive storage pair, treat updates exactly like other HA maintenance: keep service ownership on the peer before rebooting a storage node.

## Image design notes

### Storage image

Bakes in:

- common base tools from the original `common` role
- hardening packages (`nftables`, `audit`, `rsyslog`, `watchdog`)
- ZFS from the OpenZFS EL9 repository, built with DKMS for the image kernel
- backend and client-facing iSCSI packages
- Pacemaker / Corosync / pcs / fence agents
- NFS + Samba packages
- Cockpit packages
- Prometheus exporters and hardware monitoring tools

### Quorum image

Bakes in only what the quorum node needs:

- common base tools
- hardening packages
- Pacemaker / Corosync / pcs / fence agents
- monitoring packages
- no ZFS, no iSCSI target/initiator, no NFS/SMB, no Cockpit plugins

### Automatic updates

The image masks the default `bootc-fetch-apply-updates.timer` so nodes do not auto-apply updates in the middle of cluster operations. Use controlled rolling maintenance instead.

### Root filesystem and read-only `/`

The image sets XFS as the default installed root filesystem and enables composefs for a read-only deployment layout.

### 45Drives Cockpit plugins

The 45Drives repository install is kept as a best-effort optional step in the storage image build because those packages are external to the CentOS Stream base.
