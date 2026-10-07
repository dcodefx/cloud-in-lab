# Project Constraints and Solutions

This file lists the project's **known limits** and how they are handled at
**homelab / simulation** scale.

**Principle:** Most of the promised structure is built (PKI, AppRole, backup,
Cilium, gateway TLS…). The items here are deliberately unscaled areas:
production-grade orchestration, full CRL infrastructure, multi-node HA, etc.
They are considered **overengineering**; most are resolved with **simple procedure, an
existing script, or a short TTL**.

This file is neither a **todo backlog** nor a **status report**. It does not track
effort items; each stated limit is handled as described, as-is.

Related: `master-design.md` (backup flow, Cilium §8.4),
`docs/en/maintenance/maintenance.md` (backup architecture),
`docs/en/openbao/openbao-architecture-guide.md` §11.2,
`docs/en/maintenance/disaster-recovery.md`,
`docs/en/openbao/openbao-rbac.md` §11.

---

## Summary

| # | Constraint | Approach | Practical counterpart | Rationale |
|---|--------|----------|-----------------|-----------------|
| 1 | No Root CA rotation runbook | Simple handling | Root **10y** + Intermediate **5y** (bootstrap); leaf **90d**; a reminder suffices | 10y in practice means rotation is future work; an automatic CA cycle is overkill |
| 2 | No CRL/OCSP installed; no PKI cert revoke **task/script** | Accepted | 90d leaf + auto-renew; on suspected leak, manual `bao …/revoke serial=…`; mount via `bao secrets list` | Full CRL + orchestration = overengineering |
| 3 | Credential lifecycle: no `secret_id_ttl`; no revoke job | Handled via TTL | Tokens **15m–24h**; narrow policy; app-remove deletes CR/Secret; stranded tokens expire with TTL | Separate token/secret orchestration is unnecessary at homelab scale |
| 4 | Single-LXC OpenBao (SPOF) | Accepted | `backup-openbao.sh` raft snapshot (restic, three backup series) + `restore.sh` + DR runbook | 3-node HA / external KMS are outside simulation scope |
| 5 | Post-upgrade sealed risk | Simple handling | Pre-upgrade snapshot + `unseal.sh`; DR-like steps | Auto-unseal optional; SoftHSM as an extra layer is unnecessary for now |
| 6 | No separate Intermediate key export backup | By design | Raft + disk backup suffice; internal key never leaves | Separate key-archive / HSM = overkill |
| 7 | Shared wildcard surface | Accepted + existing tooling | `*.tofu.lan` on the internal network; **dedicated** Certificates where needed (already in the architecture) | No enterprise PKI process per service |
| 8 | No automatic cert-manager `secret_id` rotation | Simple handling | Re-running the `openbao-ops` playbook renews the Secret; auth is already AppRole + `secretRef` | A continuously turning rotation loop is needless complexity |
| 9 | Backup RPO depends on environment choice; no `encryption.key` backup | Simple handling | Schedule and `keep-last` defined in the role (`docs/en/maintenance/maintenance.md`); unseal key and `encryption.key` **stay outside the backup chain** | No dedicated backup platform is installed |

---

## 1. No Root CA rotation runbook

| | |
|--|--|
| **Constraint** | No written runbook for when Root expires / Intermediate renews (`docs/pki-rotation.md` does not exist). |
| **Approach** | Simple handling |
| **Practical counterpart** | TTLs are ready in code: Root `87600h` (~10y), Intermediate `43800h` (~5y), leaf `2160h` (90d) — `openbao` security/ops defaults + `bootstrap.yml`. Intermediate signing **exists in the bootstrap flow**. When needed, a one-page note + calendar reminder suffices. |
| **Rationale** | At 10y Root, an automatic rotation cycle, offline Root, portal, etc. are overengineering at homelab scale. |

---

## 2. No CRL/OCSP; no certificate revoke automation

| | |
|--|--|
| **Constraint** | No CRL/OCSP at gateway/Ingress level. No PKI **cert revoke** task in Ansible/scripts (not in app-remove either). |
| **Approach** | Accepted |
| **Practical counterpart** | Leaf **90 days** + cert-manager auto-renew. On suspected leak, the OpenBao API suffices (one manual line): `bao write <mount>/revoke serial_number=…` (mount: `bao secrets list`). Even if a CRL were produced, it would not be consumed at the homelab edge. |
| **Rationale** | Full CRL/OCSP distribution + policy point = operational load; short lifetime already narrows the risk. |

**Related (separate):** app-remove deletes **certificate CRs/Secrets**; it does not
reach OpenBao — deleting a CR writes no CRL. Lifecycle ≠ cert revoke.

---

## 3. Credential lifecycle: short tokens; deliberately no `secret_id` TTL

| | |
|--|--|
| **Constraint** | Role bodies define no `secret_id_ttl` / `secret_id_num_uses` (`openbao-rbac.md` §11: deliberate deferral). No separate revoke job. |
| **Approach** | Token TTL |
| **Practical counterpart** | **Token lifetimes** (`openbao/security/defaults` → `openbao_workload_profiles` + platform roles): workloads generally **15m–1h** (e.g. `transit-user` / `job-run`: **30m / max 1h**, batch); `metrics-reader` / `reader`: **1h / 24h** service. `token_num_uses: 0` → time-bound, unlimited uses. Authorization is narrowed via **policy + scope**. app-remove: deletes K8s objects + TLS Secret; stranded tokens **expire with TTL**. Platform (`cert-manager`, `k8s-csi`): **1h / 24h**; `openbao-ops` generates a fresh `secret_id` on every run. |
| **Rationale** | Instant token kill, accessor inventory, rotating `secret_id` cycles = too many moving parts; TTL + narrow policy suffice at homelab scale. |

**Open footnote:** §7 workload remove tries to delete the role named
`app-<scope>-<profile>`; since production uses **profile-named** roles
(`transit-user` etc.), DELETE is usually a **404 no-op** — the profile role stays
shared (correct). So the sentence "role is deleted → secret_ids are swept" is
**not valid for every workload**; scope KV entries / `outputs/*-approle.json`
cleanup are separate verification items too. If desired later: `secret_id_ttl`
(e.g. 24–72h) **or** accessor destroy on remove — both optional.

---

## 4. OpenBao single point of failure (SPOF)

| | |
|--|--|
| **Constraint** | Single LXC: PKI + secret store go down together. |
| **Approach** | Accepted |
| **Practical counterpart** | Raft: `openbao_storage_type: raft` → `/var/lib/bao/raft`. Application backup: `maintenance/backup/app-data/backup-openbao.sh` → restic → `openbao-daily` / `-weekly` / `-monthly` buckets (Garage2, `keep-last 3` per bucket); plus a 7-day local copy on OpenBao's own disk. Disk image: `maintenance/backup/vm-disk/backup-full.sh` (weekly, PVE local). Recovery is manual: `maintenance/restore/restore.sh` (see `docs/en/maintenance/disaster-recovery.md`). Manual `pct` snapshot before changes. **Snapshot ≠ backup** (same disk). |
| **Rationale** | 3-node Raft cluster, external KMS, active-active = setup/maintenance cost beyond homelab; risk consciously accepted (`master-design` §10). |

---

## 5. Post-upgrade sealed risk

| | |
|--|--|
| **Constraint** | Binary/OS upgrade restart → sealed; no separate one-page upgrade runbook. |
| **Approach** | Simple handling |
| **Practical counterpart** | Pre-upgrade raft/disk snapshot → upgrade → `scripts/openbao-unseal/unseal.sh` → `bao status` + `bao secrets list`. Unseal key **separate from backup** (password manager). Auto-unseal: `extra-samples/openbao-auto-unseal/` (default **off**, optional). |
| **Rationale** | Setting up PKCS#11 SoftHSM auto-unseal is a separate stack; and since it is software rather than a physical key, it is actually meaningless at project scale and provides no security — manual unseal + snapshot suffice for now. |

---

## 6. No separate backup for Intermediate / Root private keys

| | |
|--|--|
| **Constraint** | No "export keys and store offsite" flow for keys (we don't want one). |
| **Approach** | By design |
| **Practical counterpart** | `internal` key mode → never leaves OpenBao; raft snapshot + disk backup cover the (encrypted) mounts. Unseal key on a separate channel. |
| **Rationale** | Separate key-archive, second HSM, air-gap Root = overengineering; golden rule: unseal key ≠ same backup chain. |

---

## 7. Shared wildcard certificate

| | |
|--|--|
| **Constraint** | `*.tofu.lan` as a single surface (`gateway-tls`). |
| **Approach** | Accepted + existing tooling |
| **Practical counterpart** | Internal network + 90d auto-renew. For those wanting separate certificates, the **dedicated** path is already in the architecture (`tls.mode: dedicated`, `dedicated-pki-domains.yml`, per-app-namespace Certificate + ListenerSet). With no externally exposed services, extra CRs = extra work. |
| **Rationale** | Extra certificate policy per app; dedicated only where needed. |

---

## 8. cert-manager auth — method is clear; no automatic `secret_id` rotation

| | |
|--|--|
| **Constraint** | cert-manager AppRole `secret_id` does not rotate automatically (no loop). |
| **Approach** | Simple handling |
| **Practical counterpart** | Method **implemented**: `openbao-ops` role_id + secret_id → Secret `cert-manager-approle`; `cluster-issuer.yaml.j2` `auth.appRole` + `secretRef`. Renewal: re-running the playbook. No static tokens used. |
| **Rationale** | CSI `secretObjects` sync or hourly rotation = extra moving parts; re-running the playbook suffices at homelab scale (guide §11.2). |

---

## 9. Backup: frequency and channels (homelab template)

| Component | Method | Frequency (practical) | Note |
|---------|--------|-----------------|-----|
| Garage LXC (state) | Disk / `backup-full.sh` (`vzdump`) | Weekly (PVE host cron) | PVE local only; flat 28 days + weekly 3 / monthly 3. Tofu state store (`opentofu-state`) |
| Garage2 LXC (backup) | restic repos (bucket = repo) | Every 4 hours + weekly + monthly | **Sole store** of application backups |
| OpenBao LXC | `backup-openbao.sh` (raft) | Every 4 hours (`openbao-daily`) + Sunday (`-weekly`) + 1st of month (`-monthly`) | restic → Garage2, `keep-last 3` per bucket; 7-day local copy on disk |
| K8s Master | `backup-etcd.sh` (etcd snapshot) | Every 4 hours (`etcd-daily`) + Sunday + 1st of month | restic → Garage2; `keep-last 12` / 3 / 3 |
| Worker VMs | None | — | Stateless; Tofu rebuilds |
| `encryption.key` | **None** | — | Two copies on the controller, **same disk**; no offsite copy |
| Unseal key | **None** | — | Password manager; outside the backup channel |

Three places carry state: **Garage (state), OpenBao, etcd/master**. Backing up workers and pods is a waste of time.

**Two separate Garage LXCs exist:** the state store and the backup store are
separate; restic buckets live only on Garage2. Schedule, `keep-last`, and the
freshness threshold (`interval_h` / `tolerance_h`) are defined in
`ansible/roles/maintenance` — the trigger is a **systemd timer** (not cron).

> **CT IDs are specific to each installation.** Garage LXC identities are set
> with `chef.sh --ctid` (if left empty,
> `scripts/garage-setup/.garage-setup.env` is read); Tofu-managed LXC identities
> come from `ct_id` in `tofu/environments/<env>/*.tfvars` (e.g. laws: 302), or
> Proxmox auto-assigns a number if unset. Values in this document are
> **examples** — see `docs/en/maintenance/maintenance.md` §2 for details.

**Known limit:** Garage2 is a single LXC holding all six restic repositories;
losing this LXC takes all six application backups with it. Off-host copy
(`restic copy`) is planned, not implemented.

---

## Out of scope (not carried in this list)

| Topic | Where |
|------|--------|
| Cilium `k8s:` prefix silently skipped | Standard behavior → `master-design.md` §8.4 |
| Backup architecture, restic repos, timers | `docs/en/maintenance/maintenance.md` |
| Backup flow + DR steps | `master-design.md` §10, `docs/en/maintenance/disaster-recovery.md` |
| OpenBao engine / maturity table | `docs/en/openbao/openbao-architecture-guide.md` §11.2 |
