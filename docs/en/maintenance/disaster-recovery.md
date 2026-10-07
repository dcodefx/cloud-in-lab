# Disaster Recovery — Scenarios and Solutions

This document explains the precautions that can be taken against possible disaster scenarios, structured as scenarios and their respective solutions. The backup architecture, restic repository structure, retention limits, and monitoring chain are documented in [`maintenance.md`](maintenance.md); the `restore.sh` workflow, security steps, and rollback procedures are documented in [`restore-sh-how-it-works.md`](restore-sh-how-it-works.md).

---

## Emergency Access Information

During an emergency, the following information must be readily accessible:

| Info | Location |
|-------|-------|
| `encryption.key` | `tofu/secrets/encryption.key` (original) + `backups/encryption.key` (copy) |
| Restic passwords | `/etc/tofu-lar/backup/*.pw` (separate for each job) |
| Unseal keys | Password manager (not stored in any backup channel) |
| Garage2 S3 endpoint | `http://<garage2-ip>:3900` |
| VMIDs | On the Proxmox host via `pct list` / `qm list` |

### VMID Placeholders

The VMID values used in the following commands differ for each installation:

| Placeholder | Description | How to obtain |
|--------|-----------|-----------------|
| `<GARAGE_VMID>` | Proxmox VMID of the Garage LXC | `pct list` on the Proxmox host |
| `<OPENBAO_VMID>` | Proxmox VMID of the OpenBao LXC | `pct list` on the Proxmox host |
| `<K8S_MASTER_VMID>` | Proxmox VMID of the K8s master VM | `qm list` on the Proxmox host |

### Execution Context

| Command | Execution Context | Required Privileges |
|-------|--------------|-------|
| `restore-vm.sh` | Proxmox host | root |
| `restore-etcd.sh` | K8s master VM | root |
| `restore-openbao.sh` | OpenBao LXC | root |
| `unseal.sh` | Control machine | — |

---

## Scenario-Based Recovery Plan

### Scenario A: Kubernetes etcd Data Corruption

**Trigger:** Cluster API is unresponsive; etcd data is corrupted.

**Recovery Steps:**

```bash
# On the K8s master VM, as root
./restore/restore-etcd.sh --tier daily --yes
```

**Verification:**

```bash
kubectl get nodes
kubectl get pods --all-namespaces
```

**Note:** Any changes made after the snapshot are lost. The control plane consists of static pods; `systemctl stop etcd` does not work.

### Scenario B: Kubernetes Master Node Failure

**Trigger:** K8s master VM is unreachable.

**Recovery Steps:**

```bash
# On the Proxmox host
./restore/restore-vm.sh --vmid <K8S_MASTER_VMID> --yes
```

**Verification:**

```bash
kubectl get nodes
```

**Note:** If etcd data is intact, restoring the master VM brings the cluster back online. No etcd restore is required.

### Scenario C: OpenBao Raft Data Loss

**Trigger:** The OpenBao data layer is corrupted; secrets and PKI cannot be read.

**Recovery Steps:**

```bash
# 1. If the LXC is down, restore it first
./restore/restore-vm.sh --vmid <OPENBAO_VMID> --yes

# 2. Unseal (3/5 threshold required)
./scripts/openbao-unseal/unseal.sh

# 3. Restore the Raft snapshot (on the OpenBao LXC, as root)
./restore/restore-openbao.sh --tier daily --yes
```

**Verification:**

```bash
bao status
bao secrets list
```

**Note:** The restore rolls OpenBao data back to the snapshot point. The unseal step is mandatory; the API cannot be used while sealed.

### Scenario D: Total Loss of a Proxmox Host / Virtual Machine

**Trigger:** The Proxmox host or virtual machine is completely lost.

**Recovery Steps:**

```bash
# On the Proxmox host
./restore/restore-vm.sh --vmid <VMID> --yes
```

**Verification:**

```bash
pct status <VMID>  # or qm status <VMID>
```

**Note:** If an LXC or VM is registered under the target VMID, `restore-vm.sh` stops it, permanently deletes it with `pct destroy`/`qm destroy --purge`, and then restores to the same VMID. If the restore fails, neither the old guest nor the new copy remains.

### Scenario E: All Proxmox Hosts Lost

**Trigger:** All Proxmox hosts are lost.

**Recovery Steps:**

```bash
# 1. Garage LXC
./restore/restore-vm.sh --vmid <GARAGE_VMID> --yes

# 2. OpenBao LXC
./restore/restore-vm.sh --vmid <OPENBAO_VMID> --yes

# 3. Unseal
./scripts/openbao-unseal/unseal.sh

# 4. K8s master VM
./restore/restore-vm.sh --vmid <K8S_MASTER_VMID> --yes

# 5. etcd (on the K8s master)
./restore/restore-etcd.sh --tier daily --yes

# 6. Worker nodes → Rebuild with Tofu and Ansible
```

**Verification:**

```bash
kubectl get nodes
bao status
```

**Note:** The `restore.sh all` command performs VM/LXC and etcd recovery in a single step, but it does not include Raft recovery. Raft restore is a separate step because it can run on the OpenBao LXC after unsealing.

### Scenario F: Backup Pipeline Halted

**Trigger:** Backups are stale; the backup routine has stopped.

**Recovery Steps:**

```bash
# On any host
./restore/restore.sh health
```

**Verification:**

```bash
# If there is no [SORUN] in the output, the backups are healthy
```

**Note:** `restore.sh health` reads the last successful backup time for each job and, if the expected interval has been exceeded, prints `[SORUN]` and exits with code 1.

### Scenario G: encryption.key Lost

**Trigger:** Tofu states cannot be read.

**Recovery Steps:**

```bash
# On the control machine
cat tofu/secrets/encryption.key
# or
cat backups/encryption.key
```

**Verification:**

```bash
tofu plan
```

**Note:** Only two copies of the key exist, both on the control machine; there is no offsite copy. If the control machine's disk is lost, the Tofu states cannot be decrypted, so the key must be backed up to another location.

### Scenario H: Unseal Keys Lost

**Trigger:** OpenBao cannot be unsealed.

**Recovery Steps:**

```bash
# Get the unseal keys from the password manager
# A 3/5 threshold is required
```

**Verification:**

```bash
bao status
```

**Note:** Shamir keys are not stored in any backup channel; they exist only in the password manager.

---

## Command and Configuration Separation

**Configurations** (retention counts, timer schedules, environment variables) are documented in `maintenance.md` and `ansible/roles/maintenance/defaults/main.yml`.

**Commands:** Listed sequentially in this document in copy-paste-ready form, with parameter descriptions.

**Restore scripts:** The five scripts under `maintenance/restore/` are invoked manually; `tasks/restore.yml` is an empty placeholder and `maintenance.restore.enabled` is `false`, meaning the playbook does not run restore.

---

