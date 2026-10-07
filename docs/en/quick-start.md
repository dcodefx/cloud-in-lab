# quick_start — Quick Setup From Scratch (Single-Node Proxmox VE)

> This document assumes a single machine with only Proxmox VE 9 installed, and lists the steps to bring the platform up end to end, in order.
> For rationale, parameter details, and background, follow the **Details** links at the end of each step; only the command chain and expected behavior live here.

**Two machine models:**

| Machine | Role |
|---|---|
| **Controller** | The computer where `tofu` / `ansible` commands run (the steps in this guide run here) |
| **PVE** | Target Proxmox VE machine (single node, 9.x). All PVE scripts connect to `root@PVE` over passwordless SSH |

Example values in this document are generic (`192.168.1.x` family, `<PVE_IP>`); CT/VM identities (Garage **300**, OpenBao **301**, Laws **302**, Garage2 **320**) are symbolic and can be changed.

---

## Requirements

| Where | Needed |
|---|---|
| Controller | OpenTofu, Ansible, python3 + pyyaml, openssl, curl, bash; `~/.ssh/id_ed25519` key pair |
| PVE | Proxmox VE 9, key-based SSH for `root`, free CT/VM ID range, `local` and `local-lvm` storages (or equivalents) |

## Setup Map

```text
CORE FLOW
 1. Controller prep (SSH key + collections)
 2. PVE discovery                       → pve-discovered.txt
 3. PVE API token                   → pve-token.txt
 4. VM template                     → template_vm_id
 5. LXC templates                (OpenBao + Laws)
 6. tfvars files                 (NOT cloned, filled in by hand)
 7. State encryption key             → tofu/secrets/encryption.key
 8. Garage state store (CT 300)     → tofu/backends/*.tfbackend
 9. OpenBao LXC (tofu)               → openbao.ini.generated
10. OpenBao setup (ansible)       → init + unseal + PKI bootstrap (automatic)
11. Kubernetes VMs (tofu)        → hosts.ini.generated
12. Kubernetes setup (ansible)    → Cilium + Gateway + CSI + OpenBao integration
OPTIONAL
13. Kubernetes applications          (prom_stack + apps[])
14. Emulators: Floci + Laws
15. Databases + EFK                  (VM level only — WIP)
16. Backup infrastructure              (Garage2 CT 320 + maintenance)
```

Why this order: **Garage is the store for tofu state and is set up outside tofu** (the state infrastructure must be ready before tofu init); **OpenBao is set up before K8s** (the K8s playbook's pre-check looks for the `outputs/openbao/openbao-config.json` file).

---

# Core Flow

## Step 1 — Controller prep

**Needed:** PVE root access; Ansible installed on the controller.

**Command:**

```bash
# SSH key pair (if missing)
ssh-keygen -t ed25519 -f ~/.ssh/id_ed25519 -N "" -C "tofu-lar@controller"

# Copy the key to PVE (all PVE scripts require passwordless root SSH)
ssh-copy-id -i ~/.ssh/id_ed25519.pub root@<PVE_IP>

# Ansible collections
cd ansible
ansible-galaxy collection install -r requirements.yml
cd ..
```

**What it does:** All PVE scripts connect over `BatchMode` (passwordless) SSH; without a key the scripts fail without asking for a password. `requirements.yml` installs these collections: `kubernetes.core`, `community.general`, `community.docker`, `ansible.posix`.

**Verify:** `ssh root@<PVE_IP> hostname` returns without asking for a password.

**Details:** [docs/en/proxmox/proxmox-preps.md](docs/en/proxmox/proxmox-preps.md)

## Step 2 — PVE discovery

**Needed:** Step 1.

**Command:**

```bash
./scripts/proxmox/discover-pve.sh <PVE_IP>
```

**What it does:** Collects `target_node` (PVE hostname), gateway, bridge, subnet, storage list, and the current VM/LXC inventory from PVE → `scripts/proxmox/pve-discovered.txt`. These values go into the tfvars files in Step 6.

**Verify:** node and storage values visible inside `pve-discovered.txt`.

**Details:** [docs/en/proxmox/proxmox-preps.md](docs/en/proxmox/proxmox-preps.md)

## Step 3 — PVE API token

**Command:**

```bash
./scripts/proxmox/setup-proxmox-token.sh --host <PVE_IP>
```

**What it does:** Creates the `TerraformProv` role + `terraform-prov@pve` user + `terraform` token (on PVE 9 the token is created with `--privsep=0`) → `scripts/proxmox/pve-token.txt`. The token is shown only once; `--force` invalidates the old token (the tofu configuration must be updated too).

**Verify:** the `proxmox_token = "..."` line inside `pve-token.txt`.

**Details:** [docs/en/proxmox/proxmox-preps.md](docs/en/proxmox/proxmox-preps.md)

## Step 4 — VM template (for K8s / Databases / EFK / Floci VMs)

**Command:**

```bash
./scripts/proxmox/create-vm-template.sh --host 164.102.98.16 --distro debian --version 13 --use-virt-customize --vmid 9000
./scripts/proxmox/create-vm-template.sh --host 164.102.98.16 --distro ubuntu --version 26.04 --use-virt-customize --vmid 9010
```

**What it does:** Downloads the cloud image to PVE, verifies it, and creates a QEMU VM template. The resulting **VM ID** is written as `template_vm_id` in Step 6. The dev environment was prepared with the Debian 13 template; Ubuntu works too (`--distro ubuntu --version 26.04`). Cloud-init metadata requires a storage with **Snippets** content on PVE — the script warns if missing (Datacenter → Storage → local → Edit → Content → Snippets).

**Verify:** the new template visible in `ssh root@<PVE_IP> "qm list"`.

**Details:** [docs/en/proxmox/how-to-create-vm-template.md](docs/en/proxmox/how-to-create-vm-template.md)

## Step 5 — LXC templates (OpenBao + Laws)

**Command:**

```bash
ssh root@<PVE_IP> "pveam update && pveam download local ubuntu-26.04-standard_26.04-1_amd64.tar.zst"
```

**What it does:** Downloads the Ubuntu 26.04 template for the OpenBao (CT 301) and Laws (CT 302) LXCs to `local` storage. `chef.sh` downloads Garage's Alpine template itself; nothing is done by hand in this step.

**Verify:** `ubuntu-26.04` visible in `ssh root@<PVE_IP> "pveam list local"`.

## Step 6 — tfvars files

**Needed:** Step 2–4 outputs.

> **Caution:** tfvars files under `tofu/environments/**` do not enter git — **they don't come with the clone, they are created by hand during setup.** In the examples below, write the Step 2–3 discovery/token values and your own network values.

**Command / content:** `tofu/environments/dev/common.tfvars`:

```hcl
environment    = "dev"
target_node    = "pve"        # pve-discovered.txt: PVE hostname
template_vm_id = 9000         # Real VM ID from Step 4 output

base_ip   = "192.168.1.0"     # your own network (pve-discovered.txt)
ip_mask   = "24"
gateway   = "192.168.1.1"

ssh_pub_key_path = "~/.ssh/id_ed25519.pub"

proxmox_endpoint = "https://192.168.1.10:8006"
proxmox_token    = "terraform-prov@pve!terraform=<uuid>"   # from pve-token.txt
```

`tofu/environments/dev/k8s-cluster.tfvars`:

```hcl
node_pools = {
  masters = {
    role              = "k8s-master"
    vm_name           = "k8s-master"
    vm_count          = 1
    cpu_cores         = 2
    vm_memory         = 4096
    disk_size         = 40
    disk_storage      = "local-lvm"
    data_disk_enabled = false
    data_disk_size    = 0
    data_disk_storage = "local-lvm"
    ip_start_index    = 174      # last octet: master .174
    #template_vm_id = 9010 to override the one in common.
  }
  workers = {
    role              = "k8s-worker"
    vm_name           = "k8s-worker"
    vm_count          = 2
    cpu_cores         = 2
    vm_memory         = 6192
    disk_size         = 50
    disk_storage      = "local-lvm"
    data_disk_enabled = false
    data_disk_size    = 0
    data_disk_storage = "local-lvm"
    ip_start_index    = 184      # workers .184, .185
  }
}
```

`tofu/environments/dev/openbao.tfvars`:

```hcl
template_file_id   = "local:vztmpl/ubuntu-26.04-standard_26.04-1_amd64.tar.zst"
cpu_cores         = 1
memory_dedicated  = 2048
disk_size         = 20
protection        = false
base_ip           = "192.168.1.0"
ip_mask           = 24
ip_offset         = 186        # OpenBao .186
gateway           = "192.168.1.1"
dns_server        = "1.1.1.1"
```

`tofu/environments/dev/databases.tfvars`:

```hcl
db_instances = {
  primary = {
    role              = "database"
    vm_name           = "db-primary"
    vm_count          = 1
    cpu_cores         = 2
    vm_memory         = 2048
    disk_size         = 20
    disk_storage      = "local-lvm"
    data_disk_enabled = true
    data_disk_size    = 50
    data_disk_storage = "local-lvm"
    ip_start_index    = 190
  }
}
```

`tofu/environments/dev/efk.tfvars`:

```hcl
efk_pools = {
  elasticsearch = {
    role              = "elasticsearch"
    vm_name           = "elasticsearch"
    vm_count          = 1
    cpu_cores         = 2
    vm_memory         = 8192
    disk_size         = 20
    disk_storage      = "local-lvm"
    data_disk_enabled = true
    data_disk_size    = 50
    data_disk_storage = "local-lvm"
    ip_start_index    = 195
  }
}
```

`tofu/environments/dev/floci.tfvars`:

```hcl
cpu_cores = 2
vm_memory = 4096
disk_size = 40
ip_offset = 200        # Floci .200
```

`tofu/environments/dev/laws.tfvars`:

```hcl
ct_id            = 302
cpu_cores        = 1
memory_dedicated = 2048
disk_size        = "20"
ip_offset        = 201        # Laws .201
template_file_id = "local:vztmpl/ubuntu-26.04-standard_26.04-1_amd64.tar.zst"
```

**What it does:** `deploy.sh` passes `common.tfvars` + the relevant stack tfvars together on every run; if either is missing from disk, the run doesn't start.

**Details:** [docs/en/proxmox/proxmox-preps.md](docs/en/proxmox/proxmox-preps.md)

## Step 7 — State encryption key

**Command:**

```bash
./scripts/tofu-keys/init-encryption.sh
cp tofu/secrets/encryption.key backups/encryption.key
```

**What it does:** Generates the `tofu/secrets/encryption.key` file (random 32 bytes, `chmod 600`) and prints backup instructions to the screen — it doesn't copy the key automatically; the backup copy under `backups/` is taken with the `cp` command above. The state of the `k8s-cluster`, `databases`, `efk`, and `openbao` stacks is encrypted with a key derived from this one via PBKDF2 + AES-GCM (floci and laws excluded — they're for emulation). **If the key is lost, the states can't be read back**; so the backup copy is mandatory. `--force` leaves old states unreadable.

**Verify:** `ls -l tofu/secrets/encryption.key backups/encryption.key`

## Step 8 — Garage state store (CT 300)

**Needed:** Step 1 (SSH), Step 7 (encryption key).

**Command:**

```bash
cd scripts/garage-setup
cp garage-setup.env.example .garage-setup.env
# Edit GARAGE_PVE_IP=<PVE_IP> inside .garage-setup.env
./chef.sh --tofu-backend true
cd ../..
```

**What it does:** Sets up the Garage LXC **outside tofu** (the state infrastructure must be ready before tofu init): launches an Alpine LXC, generates the `opentofu-state` bucket + S3 key, pulls the credential as `garage-300-credentials.txt`, **automatically writes a separate `tofu/backends/<stack>.backend.tfbackend` file per stack** (each stack's state is kept in its own object in Garage; these files are direct inputs to tofu init), and protects the CT against deletion. The LXC IP (e.g. `.100`) is chosen interactively; post-setup instructions print to the screen.

**Verify:** `curl http://<garage-ip>:3900/` returns an HTTP response; 6 `.backend.tfbackend` files under `ls tofu/backends/`.

**Details:** [docs/en/garagehq/chef-sh-how-it-works.md](docs/en/garagehq/chef-sh-how-it-works.md)

## Step 9 — OpenBao LXC (tofu)

**Command:**

```bash
cd tofu
./deploy.sh dev openbao
cd ..
```

**What it does:** Provisions the OpenBao LXC (CT 301, Ubuntu 26.04) and generates the `ansible/inventory/openbao.ini.generated` inventory. `deploy.sh` = `tofu init -backend-config=backends/openbao.backend.tfbackend` + `tofu apply` (confirmation asked interactively).

**Verify:** CT 301 visible in `ssh root@<PVE_IP> "pct list"`; `ls ansible/inventory/openbao.ini.generated`.

**Details:** [platform-handbook.md](docs/en/platform-handbook.md) §3.5, §3.7

## Step 10 — OpenBao setup (Ansible)

**Command:**

```bash
cd ansible
ansible-playbook -i inventory/openbao.ini.generated playbooks/openbao.yml
cd ..
```

**What it does:** Installs OpenBao 2.6.2; **init (Shamir 3/5) + unseal + PKI Root/Intermediate CA + all policies/roles/mounts are done automatically** — no manual unseal or PKI step. During init, unseal keys and the root token are **automatically** written to these files (0600):

- `ansible/outputs/openbao/openbao-unseal-keys.txt` — human-readable summary (threshold, host, root token, unseal key list)
- `ansible/outputs/openbao/openbao-credentials.yml` — YAML copy read on re-runs
- `scripts/openbao-unseal/credentials.txt` — the file `unseal.sh` reads automatically; updated on every init

Also `ansible/outputs/openbao/openbao-config.json` (the K8s playbook looks for it) and platform token files like `ops-admin.json` are generated.

**Manual step:** Copy the unseal keys and root token from these files into **a password vault**. If OpenBao is sealed after a PVE/LXC reboot: `./scripts/openbao-unseal/unseal.sh` (it reads credentials.txt itself).

**Verify:** `curl -sk https://<openbao-ip>:8200/v1/sys/health | jq` → `"initialized": true, "sealed": false`

**Details:** [docs/en/openbao/openbao-architecture-guide.md](docs/en/openbao/openbao-architecture-guide.md)

## Step 11 — Kubernetes VMs (tofu)

**Command:**

```bash
cd tofu
./deploy.sh dev k8s-cluster
cd ..
```

**What it does:** Clones 1 master + 2 worker VMs from the Step 4 template and generates the `ansible/inventory/hosts.ini.generated` inventory. VMs may not be SSH-ready until cloud-init finishes first boot (Ansible's pre-check waits up to 120s).

**Verify:** `tofu output` (inside tofu/stacks/k8s-cluster) prints the IP list.

## Step 12 — Kubernetes setup (Ansible)

**Command:**

```bash
cd ansible
ansible-playbook -i inventory/hosts.ini.generated playbooks/k8s.yml
cd ..
```

**What it does:** Installs the kubeadm cluster: Cilium CNI + LoadBalancer/Gateway API + metrics-server + cert-manager + Secrets Store CSI + **OpenBao integration (openbao-ops role)** + Cilium network policies + 5 human kubeconfigs. **Step 10 is mandatory** — the pre-check stops at the start of the playbook if `outputs/openbao/openbao-config.json` is missing. Outputs: `admin/developer/deployer/monitoring/viewer` kubeconfigs under `ansible/outputs/k8s/`.

**Verify:** `kubectl --kubeconfig ansible/outputs/k8s/admin.conf get nodes` → 3 nodes `Ready`.

**Details:** [platform-handbook.md](docs/en/platform-handbook.md) §3.8

---

# Optional Parts

## Step 13 — Kubernetes applications

**Command:**

```bash
cd ansible
ansible-playbook -i inventory/hosts.ini.generated playbooks/k8s_apps.yml
cd ..
```

**What it does:** Installs `charted.prom_stack` (kube-prometheus-stack: Prometheus + Grafana + Alertmanager) and applications with `enable: true` in `apps[]`. Single app/chart: `-e app_filter=<name>` / `-e chart_filter=<name>`. Semantics: **apply only looks at `enable`**; `state: absent` is only meaningful in the remove playbook. The Grafana admin password (the example value in `group_vars/all/k8s_apps.yml`) is changed before installation.

**Details:** [docs/en/architecture/k8s-apps-design.md](docs/en/architecture/k8s-apps-design.md)

## Step 14 — Emulators: Floci (VM) + Laws (LXC)

**Command:**

```bash
# Floci
cd tofu && ./deploy.sh dev floci && cd ..
cd ansible && ansible-playbook -i inventory/floci.ini.generated playbooks/floci.yml && cd ..

# Laws
cd tofu && ./deploy.sh dev laws && cd ..
cd ansible && ansible-playbook -i inventory/laws.ini.generated playbooks/laws.yml && cd ..
```

**What it does:** Floci: VM + Docker + LocalStack-compatible AWS emulator (port 4566). Laws: LXC + single Rust binary + systemd (port 4566). Floci stack's `ssh_user` default is environment-specific — change it to your own username in `tofu/stacks/floci/common.tofu` before setup. floci/laws states aren't encrypted (they're for emulation).

**Verify:** `curl http://<floci-ip>:4566/_localstack/health` and `curl http://<laws-ip>:4566/health`.

**Details:** [docs/en/emulators/laws-test-commands.md](docs/en/emulators/laws-test-commands.md)

## Step 15 — Databases + EFK (WIP)

**Command:**

```bash
cd tofu && ./deploy.sh dev databases && cd ..
cd tofu && ./deploy.sh dev efk && cd ..
```

**What it does:** Only provisions the VMs (db-primary: +50 GB data disk; elasticsearch: 8 GB RAM + 50 GB data disk). These two stacks are **WIP**: no Ansible roles yet; the VMs don't join the K8s cluster and can run at any point, independent of order.

## Step 16 — Backup infrastructure (Garage2 + maintenance)

**Needed:** Steps 9–11 must be done — the maintenance inventory derives from tofu-generated `hosts.ini.generated` + `openbao.ini.generated`.

**Command:**

```bash
cd scripts/garage-setup
./chef.sh --tofu-backend false --enable-ssh true --ctid 320 --disk 8
cd ../..

cd ansible
ansible-playbook -i inventory/maintenance-320.ini.generated playbooks/maintenance.yml
cd ..
```

**What it does:** Launches the second Garage (CT 320) as backup store: skips the `opentofu-state` buckets, installs node_exporter + python3, **generates the restic passwords** (`ansible/outputs/garage-backups/ct-320/restic-*.pw`), and writes the maintenance inventory (`maintenance-320.ini.generated`). `maintenance.yml`: 6 restic backup jobs + systemd timers + node_exporter metrics + alerts. If a restic password is lost, all backups in that bucket are gone — passwords are never regenerated; copy them to the password vault.

**Verify:** the `maintenance.yml` run ends with `failed=0`.

**Details:** [docs/en/maintenance/maintenance.md](docs/en/maintenance/maintenance.md) §4.4

---

# Appendices

## A. Environment Adaptation Table

| Value | Where | What to write |
|---|---|---|
| `<PVE_IP>` | all commands | PVE machine's address |
| `target_node` | `tofu/environments/dev/common.tfvars` | PVE hostname (Step 2 discovery output) |
| `template_vm_id` | `common.tfvars` | VM ID from Step 4 output |
| `base_ip` / `ip_mask` / `gateway` | `common.tfvars` + `openbao.tfvars` | Your own network (Step 2 discovery output) |
| `ip_start_index` / `ip_offset` | stack tfvars files | Your own IP plan (free last-octet ranges) |
| `ct_id` (301, 302, 320) / `GARAGE_CT_ID` (300, 320) | `laws.tfvars`, `.garage-setup.env`, `--ctid` | Non-conflicting free CT IDs |
| `disk_storage` / `data_disk_storage` | stack tfvars files | PVE storage name (`pvesm status`; default `local-lvm`) |
| `LXC template_file_id` | `openbao.tfvars`, `laws.tfvars` | Real template name from `pveam list local` output |
| `ssh_user` (Floci) | `tofu/stacks/floci/common.tofu` | Your own username |
| `root_password` (OpenBao) | added into `openbao.tfvars` as `root_password = "..."` | Stack default is an example value; write your own strong password |
| `openbao.pki.domain` (base_domain) | `ansible/inventory/group_vars/all/all.yml` | Default internal domain; your own domain if wanted |
| `k8s_cluster.lb_ip_pool` | `all.yml` | Unused IP range in your subnet (Gateway LoadBalancer pool) |
| `openbao.rbac.ops_admin_cidrs` | `all.yml` | CIDRs the ops-admin token can connect from (empty = unlimited; narrowing recommended) |
| `maintenance.homelab_cidr` | `group_vars/all/maintenance.yml` | Same network as `base_ip`/`ip_mask` |
| Grafana `admin_password` | `group_vars/all/k8s_apps.yml` | Change the example value |

The network bridge is fixed as `vmbr0` in the tofu modules; using a different bridge requires updating `tofu/modules/proxmox-vm/main.tf` and `tofu/modules/proxmox-lxc/main.tf`.

## B. Critical Warnings

1. **Files not tracked by git** (they don't come with the clone, they're generated during setup — covered by `.gitignore`): `tofu/environments/**/*.tfvars`, `tofu/secrets/encryption.key`, `tofu/backends/*.tfbackend`, `scripts/proxmox/pve-token.txt`, `scripts/garage-setup/.garage-setup.env`, `scripts/garage-setup/garage-*-credentials.txt`, `scripts/openbao-unseal/credentials.txt`, `ansible/outputs/**`, `ansible/inventory/*.ini.generated`. No third copy of these files is kept outside the password vault / local backup.
2. If **encryption.key** is lost, states can't be read back → the `backups/encryption.key` copy is mandatory (Step 7).
3. **State layout:** Each stack uses its own separate state object in Garage (`tofu/backends/<stack>.backend.tfbackend` → `<stack>/terraform.tfstate`); stacks don't touch each other's state.
4. **The S3 backend has no locking** — no parallel `tofu apply` on the same stack.
5. **Restic passwords** are never overwritten / regenerated; lost password = total loss of that bucket's backups.
6. **After PVE reboot**, if OpenBao is sealed → `./scripts/openbao-unseal/unseal.sh`.

## C. Quick Health Checks

| Target | Command | Expected |
|---|---|---|
| Garage S3 | `curl http://<garage-ip>:3900/` | HTTP response |
| OpenBao | `curl -sk https://<openbao-ip>:8200/v1/sys/health` | `initialized: true, sealed: false` |
| Kubernetes | `kubectl --kubeconfig ansible/outputs/k8s/admin.conf get nodes` | 3 nodes `Ready` |
| Floci | `curl http://<floci-ip>:4566/_localstack/health` | Service list |
| Laws | `curl http://<laws-ip>:4566/health` | Health response |

Application hostnames (e.g. `echo.<base_domain>`) resolve to the Gateway's LoadBalancer IP (from the `lb_ip_pool` pool) via `/etc/hosts`.

## D. Post-Setup Reading List

| Document | Content |
|---|---|
| [platform-handbook.md](docs/en/platform-handbook.md) | Platform handbook: architecture, deploy order (§3.2), components |
| [docs/en/architecture/master-design.md](docs/en/architecture/master-design.md) | General architecture |
| [docs/en/openbao/openbao-architecture-guide.md](docs/en/openbao/openbao-architecture-guide.md) | OpenBao architecture and operations |
| [docs/en/openbao/openbao-rbac.md](docs/en/openbao/openbao-rbac.md) | W/P/S identity catalog, policy bundles |
| [docs/en/garagehq/chef-sh-how-it-works.md](docs/en/garagehq/chef-sh-how-it-works.md) | Full account of the Garage setup orchestrator |
| [docs/en/maintenance/maintenance.md](docs/en/maintenance/maintenance.md) | Backup/restore architecture |
| [docs/en/maintenance/disaster-recovery.md](docs/en/maintenance/disaster-recovery.md) | Scenario-based recovery |
| [docs/en/cloud-equivalents.md](docs/en/cloud-equivalents.md) | Cloud equivalents comparison |
