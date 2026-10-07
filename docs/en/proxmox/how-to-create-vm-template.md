# create-vm-template.sh — Usage Guide

A dynamic and extensible script that creates cloud-image based VM templates on Proxmox VE 8/9. It produces clean, cloud-init enabled templates to be used as `template_vm_id` in an OpenTofu/Terraform IaC workflow.

---

## Requirements

- **On the machine running the script:** `bash`, `ssh`, `base64` — must be installed.
- **On the Proxmox host:** SSH access as `root` (key-based auth recommended to avoid password prompts), `wget`, standard Proxmox tools (`qm`, `pvesh`, `pvesm`) — these are already present in every Proxmox installation
- Internet access (the cloud image is downloaded from the Proxmox host)

```bash
chmod +x create-vm-template.sh
```

---

## Quick Start

> **Note:** All IP addresses and example outputs in this document are **for illustration purposes only**; replace them with your own Proxmox host address.

```bash
./create-vm-template.sh --host 164.102.98.152 --distro ubuntu --version 24.04
```

This single command:
1. Downloads the Ubuntu 24.04 (noble) cloud image to the Proxmox host
2. Verifies its checksum
3. Finds an empty VM ID (automatically)
4. Creates the VM, imports the disk, attaches the cloud-init disk
5. Configures qemu-guest-agent to be installed on first boot
6. Converts the VM into a template

At the end you will see:
```
vm_id   = 9002
vm_name = ubuntu-24.04-template
storage = local-lvm
```

All you have to do is write this ID into the `template_vm_id` variable in your OpenTofu/Terraform config.

---

## Previewing the plan first: `--dry-run`

Shows what the script will do without performing any action — it does not even open an SSH connection:

```bash
./create-vm-template.sh --host 164.102.98.152 --distro rocky --version 9 --dry-run
```

```
=== Plan ===
  Host:        164.102.98.152
  Distro:      rocky (9)
  Image URL:   https://dl.rockylinux.org/pub/rocky/9/images/x86_64/Rocky-9-GenericCloud-Base.latest.x86_64.qcow2
  OS family:   rhel
  VM ID:       <auto>
  VM name:     rocky-9-template
  ...
```

If a wrong version/distro was entered or an invalid input was supplied, you can spot it here, before any real download or VM creation begins.

---

## Supported distributions

```bash
./create-vm-template.sh --list-distros
```

| Distribution | `--distro` | Supported `--version` | Default |
|---|---|---|---|
| Ubuntu | `ubuntu` | 20.04, 22.04, 24.04, 24.10, 25.04, 25.10, 26.04 | 24.04 |
| Debian | `debian` | 11, 12, 13 | 13 |
| Rocky Linux | `rocky` | 8, 9 | 9 |
| AlmaLinux | `almalinux` (or `alma`) | 8, 9 | 9 |

For these four distributions the URLs are **derived automatically from the version number** — different versions can be supplied via the `--version` parameter.

### A distribution not on the list (Fedora, openSUSE, Arch, custom image...)

Any cloud image can be used with `--image-url` + `--os-family`:

```bash
./create-vm-template.sh --host 164.102.98.152 \
  --image-url https://download.fedoraproject.org/pub/fedora/linux/releases/42/Cloud/x86_64/images/Fedora-Cloud-Base-42-1.1.x86_64.qcow2 \
  --os-family rhel \
  --name fedora-42-template
```

`--os-family` accepts the following values: `debian` | `rhel` | `arch` | `suse` — it determines which package manager (apt/dnf/pacman/zypper) is used to install qemu-guest-agent.

---

## Examples

### 1. Ubuntu template with default settings
```bash
./create-vm-template.sh --host 164.102.98.152
```
(distro=ubuntu, version=24.04, storage=local-lvm, vmid=auto)

### 2. A specific VM ID and ZFS storage
```bash
./create-vm-template.sh --host 164.102.98.152 \
  --distro debian --version 13 \
  --vmid 9010 --storage local-zfs
```

### 3. A beefier template (4 cores, 4GB RAM, 20GB disk)
```bash
./create-vm-template.sh --host 164.102.98.152 \
  --distro rocky --version 9 \
  --cores 4 --memory 4096 --disk-size 20G
```

### 4. Cloud-init user + SSH key + DNS baked in
```bash
./create-vm-template.sh --host 164.102.98.152 \
  --distro ubuntu --version 24.04 \
  --ciuser devops \
  --ssh-pubkey-file ~/.ssh/id_ed25519.pub \
  --nameserver 1.1.1.1 --searchdomain lab.local
```
Every VM cloned from this template comes up on first boot with the `devops` user and your public key already in place — you can SSH straight in with Ansible.

### 5. VLAN-tagged bridge
```bash
./create-vm-template.sh --host 164.102.98.152 \
  --distro debian --bridge vmbr0 --vlan 30
```

### 6. For an image that requires UEFI (OVMF)
```bash
./create-vm-template.sh --host 164.102.98.152 \
  --distro rocky --version 9 --bios ovmf
```
(When `--bios ovmf` is supplied, `--machine` automatically becomes `q35` and `efidisk0` is added automatically — no manual configuration needed.)

### 7. Overwriting an existing VM ID
```bash
./create-vm-template.sh --host 164.102.98.152 \
  --vmid 9000 --distro ubuntu --force
```
If `--force` is not supplied, the script **fails and stops** when the ID is already in use — this prevents accidental overwrites.

### 8. Baking qemu-guest-agent into the image (instead of installing it at cloud-init first boot)
```bash
./create-vm-template.sh --host 164.102.98.152 \
  --distro debian --use-virt-customize
```
The default behavior (installing via cloud-init on first boot) does not install any package on the host. If `--use-virt-customize` is supplied, `libguestfs-tools` is installed on the Proxmox host and the agent is baked directly into the image file — this yields a "cleaner" image but adds an extra dependency to the host. For most use cases, the default behavior is sufficient.

---

## All parameters

| Parameter | Description | Default |
|---|---|---|
| `--host <ip>` | **(required)** Proxmox host address | — |
| `--distro <name>` | ubuntu / debian / rocky / almalinux | `ubuntu` |
| `--version <version>` | Distribution version | per distribution |
| `--image-url <url>` | Custom/unlisted cloud image | — |
| `--os-family <family>` | Used together with `--image-url`: debian/rhel/arch/suse | — |
| `--vmid <id>` | Fixed VM ID | automatic (`pvesh nextid`) |
| `--name <name>` | Template name | `<distro>-<version>-template` |
| `--storage <name>` | Proxmox storage name | `local-lvm` |
| `--bridge <name>` | Network bridge | `vmbr0` |
| `--vlan <tag>` | VLAN tag | — |
| `--cores <n>` | Number of CPU cores | `2` |
| `--memory <MB>` | RAM (MB) | `2048` |
| `--disk-size <size>` | Grow the disk to this size (e.g. `20G`) | the image's own size |
| `--cpu-type <type>` | QEMU CPU type | `host` |
| `--bios <seabios\|ovmf>` | BIOS type | `seabios` |
| `--ciuser <user>` | Cloud-init default user | image default |
| `--ssh-pubkey-file <path>` | Public key file on the local machine | — |
| `--nameserver <ip>` | DNS server | — |
| `--searchdomain <domain>` | DNS search domain | — |
| `--use-virt-customize` | Bake the agent into the image (installs libguestfs on the host) | disabled (cloud-init is used) |
| `--force` | Delete the existing VM ID and recreate it | disabled |
| `--keep-image` | Do not delete the downloaded image | disabled (image is removed) |
| `--strict-checksum` | Stop if the checksum does not match | disabled (warns and proceeds) |
| `--dry-run` | Show the plan without performing any action | disabled |
| `--list-distros` | List supported distributions/versions | — |
| `-h`, `--help` | Help text | — |

---

## How it works (short architecture summary)

1. **Local side** (`bash create-vm-template.sh ...`): Parses the arguments, computes the actual download URL and checksum URL from the distro name + version (`resolve_distro()`), then sends all parameters to the Proxmox host in a single SSH session.
2. **Remote side** (embedded script running on the Proxmox host): Downloads the cloud image, verifies the checksum, creates an empty VM with `qm create`, imports the disk with `qm importdisk`, locates the correct volid — **regardless of storage type** (by reading the `unused0` disk from the `qm config` output) — and attaches it to `scsi0`, adds the cloud-init disk, grows the disk if requested, and finally converts it into a template with `qm template`.
3. If any step fails (`trap cleanup`), the half-built VM created up to that point is deleted automatically — no "ghost" VM ID is left behind.

---

## Troubleshooting

**"virt-customize not found" / package installation error (with `--use-virt-customize`)**
The Proxmox host needs internet access and working `apt` repositories. Alternative: do not use this flag at all; the default cloud-init approach already works and does not install any package on the host.

**"No storage supporting Snippets found" warning**
For the automatic qemu-guest-agent installation via cloud-init, at least one storage on Proxmox must support the "Snippets" content type. In the Web UI: *Datacenter → Storage → local → Edit → Content → check the "Snippets" box*. The template is still created without this setting; it's just that the agent is not installed automatically (you would need to install it on the VM manually afterwards).

**Checksum mismatch**
This can occasionally be caused by mirror lag/synchronization differences. If you did not supply `--strict-checksum`, the script warns and proceeds; if you want to be sure, you can retry the download or inspect the file with `--keep-image`.

**"VM already exists" error**
Either a different `--vmid` must be supplied, or `--force` must be added if the overwrite is intentional.

---

**General template:**

```bash
./create-vm-template.sh --host <IP> --distro debian --version 13 --use-virt-customize
```

**A few ready-made example commands:**
```bash
./create-vm-template.sh --host 164.102.98.16 --distro ubuntu --version 26.04 --use-virt-customize --vmid 9000


./create-vm-template.sh --host 164.102.98.16 --distro debian --version 13 --use-virt-customize --vmid 9010


./create-vm-template.sh --host 164.102.98.16 --distro rocky --version 9 --use-virt-customize --vmid 9020


./create-vm-template.sh --host 164.102.98.16 --distro debian --version 13 --use-virt-customize --vmid 9040 --cpu-type x86-64-v2-AES 
```

---

