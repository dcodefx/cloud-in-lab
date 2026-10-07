# Proxmox VE 9 — Preparation

On the Proxmox side, three things need to be prepared for OpenTofu:

1. **API token** — so Tofu can connect to Proxmox
2. **VM template** — to clone VMs from a template built from a cloud image
3. **Environment discovery** — to learn Proxmox environment details (gateway, bridge, DNS, storage, etc.)

All preparation scripts live under `scripts/proxmox/` and handle SSH internally.

> **Note:** All IP addresses, example outputs, and VM IDs below are **for illustration purposes only**; replace them with the values from your own environment.

```bash
./scripts/proxmox/discover-pve.sh 164.102.98.152         # → pve-discovered.txt
./scripts/proxmox/setup-proxmox-token.sh --host 164.102.98.152  # → pve-token.txt
./scripts/proxmox/create-vm-template.sh --host 164.102.98.152  # → creates a template in Proxmox
```

---

## Scripts

| Script | What It Does | Output |
|--------|--------------|--------|
| `discover-pve.sh <IP>` | Collects Proxmox environment details | `pve-discovered.txt` (local) |
| `setup-proxmox-token.sh --host <IP>` | Creates role + user + token | `pve-token.txt` (local) + `/root/pve-credentials.txt` (backup, optional) |
| `create-vm-template.sh --host <IP> [--distro …] [--version …]` | Creates a VM template from a cloud image | Template in Proxmox |

---

## 1. Environment Discovery

To learn Proxmox's environment details (gateway, bridge, DNS, storage, existing VMs):

```bash
./scripts/proxmox/discover-pve.sh 164.102.98.152
```

Output (`pve-discovered.txt`):

```
target_node = "pve"
gateway = "164.102.98.70"
bridge = "vmbr0"
pve_ip = "164.102.98.152"
subnet_mask = "24"
proxmox_endpoint = "https://164.102.98.152:8006"
dns = "8.8.8.8"

##### STORAGE LIST #####
local-lvm | lvmthin | rootdir,images

##### VM TEMPLATES #####
# vmid | name | status
9000 | base-vm | template

##### EXISTING VM/LXC LIST #####
101 | k8s-master | qemu | running | -
102 | k8s-worker | qemu | running | -

##### ALPINE CT TEMPLATE #####
alpine-3.23-default_20260116_amd64.tar.xz
```

This information is manually populated into `common.tfvars`.

**Output → Usage:**

| pve-discovered.txt | common.tfvars |
|-------------------|---------------|
| `target_node = "pve"` | `target_node = "pve"` |
| `gateway = "164.102.98.70"` | `gateway = "164.102.98.70"` |
| `pve_ip = "164.102.98.152"` | `proxmox_endpoint = "https://164.102.98.152:8006"` |
| `subnet_mask = "24"` | `ip_mask = "24"` |
| `proxmox_endpoint = "https://..."` | write verbatim |
| `dns = "8.8.8.8"` | no separate field for DNS, optional in Tofu |
| Storage list | reference for disk/storage definitions in `common.tfvars` |
| VM template list | shows which ID to use for `template_vm_id` |

---

## 2. API Token

### With the Script

```bash
./scripts/proxmox/setup-proxmox-token.sh --host 164.102.98.152
# Optional parameters
./scripts/proxmox/setup-proxmox-token.sh --host 164.102.98.152 --user terraform-prov --realm pve --force
```

To see all options:

```bash
./scripts/proxmox/setup-proxmox-token.sh --help
```

| Flag | Description | Default |
|------|-------------|---------|
| `--host <ip>` | **(required)** Proxmox host address | — |
| `--user <name>` | API token user | `terraform-prov` |
| `--realm <pve\|pam>` | User realm (`pve` recommended for automation) | `pve` |
| `--token-id <name>` | Token ID | `terraform` |
| `--role <name>` | Role name | `TerraformProv` |
| `--privs "<list>"` | Custom privilege list | PVE9 default privileges |
| `--acl-path <path>` | ACL scope | `/` (entire cluster) |
| `--output <file>` | Local output file | `./pve-token.txt` |
| `--force` | Deletes and recreates existing role/user/token (old token becomes invalid) | disabled |
| `--skip-backup` | Skip creating `/root/pve-credentials.txt` backup on the host | disabled (backup is created) |
| `-h`, `--help` | Show this help | — |

The script does the following:

1. Creates/updates the `TerraformProv` role with the current PVE9 privilege list; recreates it with `--force`
2. Creates the user as `terraform-prov@pve` by default / skips it if already present; realm defaults to `pve`, warns if `@pam` is selected
3. Assigns the ACL to the user under `/`
4. Creates the token `terraform-prov@pve!terraform`; idempotent. With `--force`, deletes the old token and creates a new one, making the old token invalid.
5. Writes the local `pve-token.txt` file with `chmod 600`
6. Optionally creates a backup at `/root/pve-credentials.txt` on the host; can be disabled with `--skip-backup`

To add the token line to `common.tfvars`:

```bash
cat pve-token.txt
# proxmox_token = "terraform-prov@pve!terraform=aa21c577-..."
```

**Output → Usage:**

| pve-token.txt | common.tfvars |
|--------------|---------------|
| `proxmox_token = "terraform-prov@pve!terraform=..."` | `proxmox_token = "terraform-prov@pve!terraform=..."` |

Copy and paste it into the designated location.

### Manual Method

```bash
ssh root@164.102.98.152

pveum role add TerraformProv \
  -privs "Datastore.AllocateSpace Datastore.AllocateTemplate Datastore.Audit \
Pool.Allocate Pool.Audit \
Sys.Audit Sys.Console Sys.Modify \
VM.Allocate VM.Audit VM.Clone \
VM.Config.CDROM VM.Config.Cloudinit VM.Config.CPU VM.Config.Disk \
VM.Config.HWType VM.Config.Memory VM.Config.Network VM.Config.Options \
VM.Migrate VM.PowerMgmt VM.GuestAgent.Audit \
SDN.Use"

pveum user add terraform-prov@pve
pveum acl modify / -user terraform-prov@pve -role TerraformProv

pveum user token add terraform-prov@pve terraform \
  --output-format json
```

> Note: The `pve` realm is preferred for automation. If `@pam` is used, a Linux user with the same name must exist on the host.

### Privilege Table

| Privilege | Why It Is Needed |
|-----------|------------------|
| `VM.Allocate` | Create/delete VMs |
| `VM.Clone` | Clone from template |
| `VM.Config.CPU` | CPU settings |
| `VM.Config.Memory` | RAM settings |
| `VM.Config.Disk` | Add/remove disks |
| `VM.Config.Network` | Network interface |
| `VM.Config.Cloudinit` | Cloud-init (IP, SSH key) |
| `VM.Config.Options` | VM options |
| `VM.Config.CDROM` | CD-ROM management |
| `VM.Config.HWType` | Hardware type |
| `VM.Audit` | Read VM configuration |
| `VM.PowerMgmt` | Start/stop VMs |
| `VM.Migrate` | Migrate VMs |
| `VM.GuestAgent.Audit` | Query guest agent |
| `Datastore.AllocateSpace` | Allocate disk space |
| `Datastore.AllocateTemplate` | Download/create templates |
| `Datastore.Audit` | View storage |
| `Pool.Allocate` | Add VMs to a pool |
| `Pool.Audit` | Read pool information |
| `Sys.Audit` | Read node status |
| `Sys.Console` | Console access |
| `Sys.Modify` | System settings |
| `SDN.Use` | Use SDN |

---

**Token renewal:**

```bash
pveum user token remove terraform-prov@pve terraform
pveum user token add terraform-prov@pve terraform --output-format json
./scripts/proxmox/setup-proxmox-token.sh --host 164.102.98.152 --force
```

> `--force` deletes the old token and creates a new one; all systems using the old token must be updated.

---

## 3. VM Template

> For detailed usage, all parameters, and examples, see `docs/en/proxmox/how-to-create-vm-template.md`. A summary is provided below.

### With the Script

```bash
# Ubuntu 26.04, automatic VM ID, storage local-lvm (default)
./scripts/proxmox/create-vm-template.sh --host 164.102.98.152 --distro ubuntu --version 26.04

# Debian 13, VM ID 9001, storage local-lvm
./scripts/proxmox/create-vm-template.sh --host 164.102.98.152 --distro debian --version 13 --vmid 9001 --storage local-lvm
```

The script works with built-in distro/version mappings and can also use any unlisted cloud image via `--image-url --os-family`.
This makes the distribution list fully extensible.

Parameters allow full customization of `CPU/RAM/disk` size, `BIOS/UEFI`, `bridge/VLAN`, cloud-init user/SSH key/DNS, qemu-guest-agent installation method, checksum verification, dry-run, force, and more. For the **detailed parameter set and examples**, see `docs/en/proxmox/how-to-create-vm-template.md`.

Built-in support: `ubuntu` 20.04/22.04/24.04/24.10/25.04/25.10/26.04, `debian` 11/12/13, `rocky` 8/9, `almalinux` 8/9. For the current list and defaults, use `--list-distros` or `docs/en/proxmox/how-to-create-vm-template.md`.

**Output → Usage:**

| Script output | common.tfvars |
|---------------|---------------|
| `template_vm_id = 9000` | `template_vm_id = 9000` |

Note the storage name (`local-zfs`, `local-lvm`, etc.); it will be used in the VM disk definition in `common.tfvars`.

---

## 4. common.tfvars - Variable Mapping

Values obtained from the discovery and token scripts are written into `tofu/environments/dev/common.tfvars`:

| Value | Source | common.tfvars Field |
|-------|--------|-------------------|
| PVE IP + port | `discover-pve.sh` (pve_ip) | `proxmox_endpoint = "https://164.102.98.152:8006"` |
| API token | `setup-proxmox-token.sh` | `proxmox_token = "terraform-prov@pve!terraform=..."` |
| PVE node name | `discover-pve.sh` (target_node) | `target_node = "pve"` |
| Template VM ID | `create-vm-template.sh` | `template_vm_id = 9000` |
| Network address | **Derived** from `discover-pve.sh` output (the script does not write `base_ip`; look at `pve_ip`/gateway and manually enter the network's `.0` address; e.g. `164.102.98.16` → `164.102.98.0`) | `base_ip = "164.102.98.0"` |
| Subnet mask | `discover-pve.sh` (subnet_mask) | `ip_mask = "24"` |
| Gateway | `discover-pve.sh` (gateway) | `gateway = "164.102.98.70"` |
| SSH public key | Your own SSH key | `ssh_pub_key_path = "~/.ssh/id_ed25519.pub"` |

---

## 5. Troubleshooting

| Error | Cause | Solution |
|-------|-------|----------|
| `permission denied` | Insufficient token permissions | Check whether the role has all VM.* privileges |
| `Permission check failed` / Datastore.AllocateTemplate | Token does not have permission to download templates to storage | Add `Datastore.AllocateTemplate` to the role (see the note above) |
| `no template found` | Wrong template VM ID | Verify the ID with `pvesh get /cluster/resources --type vm` |
| `disk image too large` | Not enough storage space | Check space with `pvesh get /storage/<STORAGE>/status` |
| `address already in use` | IP conflict | Check `base_ip` + `ip_start_index` |
| `could not parse token` | Wrong token format | Use the format `USER@REALM!TOKEN_ID=SECRET` |
| SSH connection refused | No access to Proxmox | Test the connection with `ssh root@<IP>` |

---
