# HA ZFS-over-iSCSI SAN — bootc Atomic Deployment + Ansible Cluster Bootstrap

This repository builds and deploys a three-node HA storage cluster:

- `storage-a` and `storage-b`: active/passive ZFS-over-iSCSI storage nodes
- `quorum`: third vote for Pacemaker/Corosync quorum
- floating VIPs for Cockpit, NFS, SMB, and client-facing iSCSI
- STONITH fencing, hardening, monitoring, and operational helper scripts

The recommended deployment path is now **bootc on CentOS Stream 9**:

- the host OS is delivered as a **bootable OCI image**
- installer ISO, qcow2, and raw artifacts are generated from that image
- node configuration and cluster bootstrap stay in **Ansible**
- rolling host updates use **`bootc upgrade` / `bootc rollback`** instead of in-place package-manager upgrades

The original mutable Ansible deployment path is still present for labs, migrations, or environments that do not want bootc yet.

## What this repo does

The cluster design stays the same as the original playbook:

- local disks on each storage node are exported to the peer over iSCSI
- ZFS mirrors each node’s local disks with the peer’s exported disks
- Pacemaker imports the pool on whichever storage node is active
- client-facing NFS, SMB, iSCSI, and VIPs follow the active node during failover

What changed is **how the operating system is delivered**:

- **bootc image build time** now handles the base OS, kernel, repositories, ZFS, iSCSI, Pacemaker, Cockpit, and monitoring packages
- **Ansible runtime** now focuses on host configuration, cluster setup, templates, firewalling, monitoring, and generated helper scripts
- **manual operator-reviewed steps** are still retained for pool creation, STONITH validation, and Pacemaker resource creation

## Recommended deployment modes

### Recommended: bootc-based atomic deployment

Use this when you want:

- repeatable installs from an ISO or VM image
- transactional OS updates with staged reboot-based activation
- rollback with `bootc rollback`
- a tighter “golden image + config” workflow

This path is centered on:

- `bootc/Containerfile.storage`
- `bootc/Containerfile.quorum`
- `bootc/build-images.sh`
- `bootc/build-artifacts.sh`
- `bootc/bootstrap-cluster.sh`

### Also available: legacy mutable Ansible deployment

You can still install a supported distro manually on all three nodes and run:

```bash
ansible-playbook -i inventory.yml site.yml
```

That path remains useful for development, comparison testing, or environments already standardized on Debian, Ubuntu, Rocky, or Alma. For new deployments, the bootc path is the intended default.

## Supported platforms

### bootc images

- **CentOS Stream 9** bootc base image
- storage image for `storage-a` and `storage-b`
- quorum image for `quorum`

### mutable playbook path

`site.yml` still validates and supports:

- Debian 12
- Ubuntu 22.04 / 24.04
- Rocky Linux 9
- AlmaLinux 9
- CentOS Stream 9

## Repository layout

```text
.
├── README.md
├── inventory.yml
├── site.yml
├── verify.yml
├── os-upgrade.yml
├── group_vars/
├── host_vars/
├── roles/
├── docs/
└── bootc/
    ├── README.md
    ├── Containerfile.storage
    ├── Containerfile.quorum
    ├── build-images.sh
    ├── build-artifacts.sh
    ├── bootstrap-cluster.sh
    ├── configs/
    │   ├── qcow2-user.example.toml
    │   ├── storage-a-installer.example.toml
    │   ├── storage-b-installer.example.toml
    │   └── quorum-installer.example.toml
    └── files/
        ├── 00-ha-san.toml
        ├── config.toml
        ├── prepare-root.conf
        ├── build-zfs.sh
        └── install-45drives.sh
```

## How the bootc split works

### Storage image (`bootc/Containerfile.storage`)

Builds the image used for `storage-a` and `storage-b` and bakes in:

- CentOS Stream 9 bootc base
- OpenZFS on EL9 with DKMS
- iSCSI initiator and target packages
- Pacemaker, Corosync, pcs, and fence agents
- NFS, Samba, Cockpit, exporters, and supporting tools
- optional 45Drives Cockpit plugins (best effort)

### Quorum image (`bootc/Containerfile.quorum`)

Builds a smaller image for `quorum` and includes:

- base admin and hardening packages
- Pacemaker, Corosync, pcs, and fence agents
- monitoring packages
- no ZFS, no iSCSI target/initiator, and no storage-service stack

### Image defaults baked into `bootc/files/`

- `00-ha-san.toml` sets the installed root filesystem type to `xfs`
- `config.toml` provides default minimum sizes for `/` and `/boot`
- `prepare-root.conf` enables `composefs`
- the default automatic update timer is masked so host upgrades happen only during planned maintenance

## Prerequisites

### 1) Build host for images and artifacts

You need a machine that can run Podman and build the bootc images.

Required:

- Podman
- enough local disk space for two images plus generated artifacts
- if SELinux is enforcing on the build host, install the OSBuild SELinux policy package required by `bootc-image-builder`

Optional but recommended:

- access to a container registry for production updates
- qemu/libvirt if you want to test qcow2 images before touching hardware

### 2) Ansible control host

You need a control machine that can reach all three nodes on the management network.

```bash
python3 -m venv .venv
source .venv/bin/activate
pip install ansible
ansible-galaxy collection install community.general
```

### 3) Target nodes

You need:

- 3 nodes total: `storage-a`, `storage-b`, `quorum`
- static management addressing for all three nodes
- a **dedicated OS boot disk** on each node
- storage data disks on the storage nodes that are **not** reused as the boot disk
- SSH access for `storageadmin`
- working fencing hardware or smart plugs before production cutover

## Files you must edit before first deployment

At minimum, review and customize:

- `inventory.yml`
- `group_vars/all.yml`
- `group_vars/storage_nodes/cluster.yml`
- `group_vars/storage_nodes/iscsi.yml`
- `group_vars/storage_nodes/network.yml` if you want the playbook to manage interfaces
- `group_vars/storage_nodes/services.yml`
- `group_vars/storage_nodes/zfs.yml`
- `host_vars/storage-a.yml`
- `host_vars/storage-b.yml`
- `host_vars/quorum.yml`

For bootc installer media, also customize one of:

- `bootc/configs/storage-a-installer.example.toml`
- `bootc/configs/storage-b-installer.example.toml`
- `bootc/configs/quorum-installer.example.toml`

Or, for qcow2/raw VM-style images:

- `bootc/configs/qcow2-user.example.toml`

Before you deploy:

- replace every `CHANGEME` or placeholder value
- move all passwords and CHAP secrets into `ansible-vault`
- replace the SSH key placeholders
- replace all disk placeholders in `host_vars/storage-a.yml` and `host_vars/storage-b.yml` with persistent `/dev/disk/by-id/...` paths
- confirm the installer disk in each bootc config is the dedicated OS disk, not a SAN data disk

Generate a password hash for installer TOMLs with:

```bash
openssl passwd -6
```

## Build and publish the bootc images

### Lab or local proof-of-concept

This is fine for building artifacts and testing locally:

```bash
./bootc/build-images.sh
```

That creates:

- `localhost/ha-san-storage:latest`
- `localhost/ha-san-quorum:latest`

### Production or long-lived deployments

For real bootc lifecycle management, build the images with a registry reference the installed hosts can reach later for `bootc upgrade`.

Example:

```bash
export STORAGE_IMAGE=registry.example.com/ha-san/storage:stable
export QUORUM_IMAGE=registry.example.com/ha-san/quorum:stable
./bootc/build-images.sh
podman push "$STORAGE_IMAGE"
podman push "$QUORUM_IMAGE"
```

A few important notes:

- bootc hosts track an image reference for future updates
- `localhost/...` is convenient for local artifact creation, but deployed nodes cannot use it as a normal remote update source
- if you prefer immutable version tags, either keep hosts tracking a moving tag such as `:stable` or switch them to a new ref during maintenance with `bootc switch`

### Optional image build knobs

Examples:

```bash
# Disable the best-effort 45Drives Cockpit plugin install
ENABLE_45DRIVES=0 ./bootc/build-images.sh

# Build from a different base reference
BASE_IMAGE=quay.io/centos-bootc/centos-bootc:stream9 ./bootc/build-images.sh
```

## Generate install media or VM artifacts

### Installer ISO (recommended for bare metal)

Create one installer per node so hostname and management addressing are baked into the kickstart.

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

Use the installer example TOMLs only after replacing all placeholders.

### QCOW2 or RAW image

Useful for virtual testbeds or alternative provisioning pipelines.

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

- the generic bootc base image does not include a default login user
- `qcow2-user.example.toml` is meant for qcow2/raw image builds
- the installer TOMLs already use kickstart to create the admin user
- do **not** mix a `[customizations.user]` block with an installer kickstart in the same build config

## Install the three nodes

Install the generated artifacts onto:

- `storage-a` with the storage image
- `storage-b` with the storage image
- `quorum` with the quorum image

After first boot, confirm:

- each node came up with the expected hostname
- management networking is correct
- the OS landed on the dedicated install disk
- you can SSH in as `storageadmin`

## Bootstrap the cluster with Ansible

Once the three nodes are installed and reachable, run the existing playbook in bootc mode:

```bash
./bootc/bootstrap-cluster.sh --ask-vault-pass
```

That expands to:

```bash
ansible-playbook -i inventory.yml site.yml -e bootc_skip_packages=true
```

This reuses the existing roles for:

- common host configuration
- hardening and firewall rules
- optional interface/networking management
- iSCSI target and initiator configuration
- Corosync and Pacemaker cluster formation
- NFS, SMB, and client-facing iSCSI configuration
- Cockpit and monitoring deployment

## Manual steps that remain on purpose

After Ansible finishes, log in to the current active storage node (normally `storage-a`) and complete the operator-reviewed steps:

```bash
# 1. Confirm the peer iSCSI sessions exist
iscsiadm -m session

# 2. Review the generated pool-creation helper and fix any path mismatches
vim /root/create-pool.sh
bash /root/create-pool.sh

# 3. Export the pool so Pacemaker can own it
zpool export san-pool

# 4. Configure fencing after verifying the fence devices are correct
bash /root/configure-stonith.sh

# 5. Create Pacemaker resources after the pool exists
bash /root/configure-pacemaker-resources.sh
```

These steps are intentionally manual because:

- ZFS pool creation is destructive and depends on verified iSCSI device paths
- fencing mistakes can power-cycle the wrong host
- Pacemaker resource creation depends on the real pool and service state

## Verification

Run the read-only verification playbook:

```bash
ansible-playbook -i inventory.yml verify.yml
```

Useful checks after the initial cutover:

```bash
pcs status
zpool status san-pool
iscsiadm -m session
bootc status
```

Recommended planned failover test:

```bash
pcs resource move zfs-pool storage-b
pcs resource clear zfs-pool
```

## Day-2 updates on bootc hosts

For bootc deployments, update the base OS by building and publishing a new image revision, then upgrade nodes one at a time.

Recommended order:

1. `quorum`
2. the standby storage node
3. the active storage node

### On the node being updated

Option A: stage first, then apply during the maintenance window:

```bash
sudo bootc upgrade --download-only
sudo bootc status --verbose
sudo bootc upgrade --from-downloaded --apply
```

Option B: fetch and apply immediately:

```bash
sudo bootc upgrade --apply
```

If you need to change the image ref the host tracks, use:

```bash
sudo bootc switch registry.example.com/ha-san/storage:stable
```

Rollback path:

```bash
sudo bootc rollback
sudo reboot
```

Operational guidance:

- always evacuate or fail over storage resources before rebooting a storage node
- wait for the upgraded storage node to rejoin cleanly before touching the peer
- if the pool resilvers after a node return, wait for the resilver to complete before upgrading the other storage node
- for bootc hosts, prefer this workflow over the package-manager procedure in `docs/os-upgrade.md`

## Reapplying configuration with tags

Most repo-managed configuration remains idempotent and can be re-applied with tags.

```bash
ansible-playbook -i inventory.yml site.yml --tags base
ansible-playbook -i inventory.yml site.yml --tags storage
ansible-playbook -i inventory.yml site.yml --tags cluster
ansible-playbook -i inventory.yml site.yml --tags services
ansible-playbook -i inventory.yml site.yml --tags cockpit
ansible-playbook -i inventory.yml site.yml --tags monitoring
```

Dry run:

```bash
ansible-playbook -i inventory.yml site.yml --check --diff
```

## Legacy mutable deployment path

If you are not using bootc yet:

```bash
ansible-playbook -i inventory.yml site.yml --ask-vault-pass
```

That path expects a fresh supported OS install on each node and lets Ansible manage packages directly. For rolling mutable-node upgrades, see:

- `os-upgrade.yml`
- `docs/os-upgrade.md`

## Additional documentation

Use these docs for deeper operational details:

- `bootc/README.md` — image-build details and artifact generation
- `docs/ha-san-design.md` — architecture and failover model
- `docs/ha-san-ops.md` — operations and maintenance guidance
- `docs/variables.md` — variable reference
- `docs/cluster-monitoring.md` — exporters, metrics, and alerting
- `docs/cockpit-ha-config.md` — Cockpit in an HA layout
- `docs/stonith-smart-plugs.md` — Kasa, ESPHome, Tasmota, and HTTP fencing patterns
- `docs/watchdog.md` — watchdog guidance
- `docs/iscsi-recovery.md` — path and session recovery
- `docs/dataset-best-practices.md` — workload-oriented dataset layout guidance

## Summary

This repo is now organized around a **bootc-first** deployment model:

1. build a bootable storage image and quorum image
2. turn those images into node install artifacts
3. install the three nodes
4. run the existing Ansible automation in `bootc_skip_packages=true` mode
5. complete the explicit storage-cluster manual steps
6. maintain the hosts with rolling `bootc upgrade` and `bootc rollback`

That keeps the HA SAN behavior and Ansible logic you already had, while making the host OS easier to deploy, standardize, update, and recover.
