# Cloud Equivalents and Similar Implementation Examples

> Versions: K8s 1.36.2 · Cilium 1.20.1 · Gateway API 1.6.1 · OpenBao 2.6.2 · cert-manager 1.21.1 · Helm 4.2.4 · kube-prometheus-stack 88.6.1 · Proxmox BPG Provider ~> 0.78 · GarageHQ 2.1.0

This document maps the Cloud-in-Lab architectural components to their equivalent cloud services and outlines the scope of implementation within this project.

---

## Core Approach

Cloud-in-Lab is used to apply similar architectural patterns of cloud infrastructure in a homelab. The goal is to test the same principles at lower cost or to provide a learning environment. This document is not intended as a "cloud vs. homelab" comparison chart — it shows which tool and what logic are used to rebuild a given cloud mechanism here.

---

## 1. Infrastructure Layer (Provisioning with OpenTofu)

OpenTofu creates VMs and LXCs on Proxmox. This structure can correspond to similar operations in cloud environments.

| Cloud-in-Lab | AWS Equivalent | Azure Equivalent | GCP Equivalent | Mechanism |
|----------|-------------|---------------|-------------|---------------|
| **VM module (clone)** | EC2 Launch Template + AMI | VMSS + Custom Image | Compute Engine + Custom Image | Cloning a VM from a golden image |
| **LXC module** | Fargate / ECS Task | Container Instances | Cloud Run | Lightweight container-based service |
| **common.tfvars** | Terraform Workspace | Subscription/Resource Group | Project/Zone | Environment-based shared configuration |
| **node_pools map** | EKS Managed Node Groups | AKS Node Pools | GKE Node Pools | Dynamic VM pools (for_each) |
| **cidrhost() IP** | VPC Static IP / ENI | VNet Static IP | Static Internal IP | Automatic IP addressing |
| **cloud-init (initialization)** | EC2 user_data + SSH key pair | Custom Data + SSH | Metadata + SSH | Initial setup configuration |
| **template_vm_id (9000)** | AMI ID | Gallery Image ID | Family Image | Shared golden image |

### Project Patterns

**VM Pattern** (for heavy workloads — K8s, CI runner):
```
Template (ID 9000) → full clone → guest agent → data disk (optional)
```
Equivalent operation: `aws ec2 run-instances --launch-template ... --image-id ami-xxx`

**LXC Pattern** (for lightweight services — OpenBao, LocalStack):
```
LXC Template (.tar.zst) → container create → unprivileged + nesting
```
Equivalent operation: `aws ecs run-task --launch-type FARGATE` (a task definition points to a pre-defined image)

### Proxmox Preparation Scripts

Before Tofu runs, three prerequisites must be met on the Proxmox side, which are handled by the scripts under `scripts/proxmox/`. Tofu itself does none of these; it only consumes their outputs (the values in `common.tfvars` and the golden image):

| Script | What It Does | Cloud Equivalent |
|---|---|---|
| `discover-pve.sh` | Collects Proxmox network/storage/existing VM information (`pve-discovered.txt`) | Discovery API calls such as `aws ec2 describe-vpcs` / `describe-subnets` |
| `setup-proxmox-token.sh` | Creates a role + user and generates an API token | Creating an IAM role + user + access key (`create-role` / `create-user` / `create-access-key`) |
| `create-vm-template.sh` | Downloads a cloud image, verifies the checksum, and produces a parametric VM template — with parameters such as `--distro`, `--version`, `--cores`, `--memory`, `--bios` for the desired combination of Ubuntu/Debian/Rocky/AlmaLinux, preview via `--dry-run`, and automatic cleanup on failure (`trap cleanup`) | AMI build pipeline with EC2 Image Builder / Packer |

---

## 2. Platform Layer (Configuration with Ansible)

Ansible installs software inside the machines that Tofu provisions. This structure can correspond to similar configuration processes in cloud environments.

| Cloud-in-Lab | AWS Equivalent | Azure Equivalent | GCP Equivalent | Mechanism |
|----------|-------------|---------------|-------------|---------------|
| **K8s Cluster** | EKS | AKS | GKE | Container orchestration |
| **Cilium CNI** | VPC CNI + Calico | Azure CNI + Calico | Dataplane V2 | Network management + network policy |
| **Gateway API + ListenerSet** | ALB/NLB + ACM cert (+ AWS Gateway API Controller) | App Gateway + Traffic Manager | Cloud Load Balancer | Ingress/egress; ListenerSet for dedicated TLS |
| **OpenBao** | KMS + Secrets Manager + ACM + STS | Key Vault + Managed Identity | Cloud KMS + Secret Manager + IAM | Secret + PKI + KMS + credential management |
| **cert-manager** | ACM (partially) | App Gateway Certs | Managed Certificates | Certificate lifecycle |
| **CSI Driver** | Secrets Manager CSI | Key Vault CSI | Secret Manager CSI | Mount secrets into pods |
| **RBAC** | IAM Roles + Policies + STS AssumeRole | Azure AD Roles + Managed Identity | IAM Roles + Service Accounts | Role-based access |
| **Workload identity (SA-JWT)** | IRSA / EKS Pod Identity | Workload Identity + Managed Identity | Workload Identity Federation | Pod: SA-JWT; outside K8s: AppRole |
| **Network Policies** | Security Groups + NACLs + WAF | NSGs + ASGs + Firewall | VPC Firewall Rules + Cloud Armor | Network filtering |

**The logic behind Cilium/eBPF:** In cloud providers, VPC Security Group / NACL rules work over IP and port — when a pod's IP changes, the rule must be recalculated. Cilium, by contrast, operates on an identity basis with eBPF: rules are bound not to the pod IP but to an identity derived from the pod's labels, so even if the pod is recreated or its IP changes, the policy remains valid. This is a fundamentally different approach from AWS's VPC CNI + Security Group model, and the default-deny/identity-based selector pattern in the project is a direct result of this difference.

---

## 3. OpenBao — Comprehensive Capabilities

OpenBao goes beyond secrets management; it brings multiple infrastructure services under one roof.

| Capability | Description | Cloud Equivalent |
|---------|----------|---------------|
| **KV v2** | Versioned key-value secret storage | AWS Secrets Manager, Azure Key Vault |
| **PKI Engine** | Root CA + Intermediate CA generation, certificate signing; for requests outside the base domain, dynamic role + ClusterIssuer via `dedicated-pki-domains.yml` | ACM Private CA / PCA (domain-constrained sub CA), Azure CA, step-ca |
| **Transit Engine** | Envelope encryption (`aes256-gcm96`); DEK/KEK separation | AWS KMS, Azure Key Vault Keys, GCP Cloud KMS |
| **AppRole Auth** | Machine identity (similar to service account) | IAM Roles, Azure Managed Identity |
| **Kubernetes Auth (SA-JWT)** | CSI login via Pod ServiceAccount JWT | IRSA / Workload Identity |
| **Database Secrets Engine** | Dynamic credential generation (with TTL) | RDS IAM Authentication, Azure AD Auth |
| **Static Secrets** | Persistent secret records | Secrets Manager, Key Vault |
| **Audit Log** | Record of all API calls | CloudTrail, Azure Activity Log |
| **Unseal Mechanism** | Threshold-based unseal (3/5 keys) | HSM-backed KMS |
| **CSI Provider** | Connecting K8s pods to OpenBao | Secrets Store CSI Driver |

**The logic behind AppRole:** In cloud environments, assigning an IAM Role to an EC2 instance occurs automatically and implicitly via the instance metadata service — the instance's identity is verified by the cloud provider itself. Because OpenBao runs outside K8s (in a separate LXC), this implicit verification mechanism does not exist; instead, AppRole uses an explicit `role_id` + `secret_id` pair — the machine identity is verified not by the cloud provider but by the defined policy. This is an example of how the mechanism that the cloud natively provides for instance identity is rebuilt in an on-prem environment.

### 3.1 RBAC / Authorization Detail (`openbao-rbac.md` §7)

Mechanism equivalents for the RBAC layer — this is the version of §1 of the plan carried over into this document:

| OpenBao | AWS IAM Equivalent | Mechanism |
|---|---|---|
| AppRole | IAM Role (machine identity) | `role_id`+`secret_id` = `AssumeRole` |
| **Kubernetes auth (SA-JWT)** | **IRSA / EKS Pod Identity** (Workload Identity) | Pod SA JWT ↔ `auth/kubernetes`; CSI path |
| Policy (HCL) | IAM Policy (JSON) | Path/capability-based |
| **Identity templating** | **IAM Policy Variables** | `{{identity...}}` ↔ `${aws:PrincipalTag/...}` |
| Entity/Group | IAM Group | Bulk policy assignment |
| `secret_id` wrapping | STS `AssumeRole` + external ID | One-time use, short TTL |
| `token_bound_cidrs` | IAM Condition `aws:SourceIp` | Network-level restriction |
| Control Groups (2.7, not yet available) | IAM Permission Boundary + approval flow | Human-in-the-loop |

> **Note (root usage):** To protect against the root token being accidentally or otherwise deleted, compromised, etc., root is not used for daily operations and is kept only for break-glass. root is used only once during the `rbac-platform.yml` bootstrap; after that, all routine work is carried out with the `ops-admin` (P4) token — details: [`openbao-rbac.md`](openbao/openbao-rbac.md) §6.2.

---

## 4. Security Layer

### 4.1 Kubernetes RBAC

| Component | Count | Description | Cloud Equivalent |
|---------|------|----------|---------------|
| **ClusterRole template** | 15 | 9 custom (pod-reader, pod-log-reader, workload-viewer, full-viewer, pod-operator, workload-operator, config-editor, deployer, monitoring-reader) + 5 aggregated (aggregated-viewer, aggregated-developer, aggregated-deployer, aggregated-admin, aggregated-monitoring) + 1 inventory loop (`custom_cluster_roles`) | IAM Custom Roles |
| **Default Kubeconfig** | 5 | `admin` (full privileges) + `deployer`, `developer`, `monitoring`, `viewer` (role-based) — generated by the `gen-kubeconfig.yml` playbook | STS AssumeRole with profile |
| **Namespace Isolation** | 1 | kubeconfig-sa (all SAs are in this namespace) | VPC per-team isolation |

> **Note:** By default, 5 kubeconfigs are generated; with `gen-kubeconfig.yml`, custom kubeconfigs can also be generated for any desired role combination — it is not limited to a fixed 5. The template total is 15 (master-design §8.5); 14 fixed-name + inventory loop.

### 4.2 Cilium Network Policies

The total number of tested active policies is **29**: **20 CCNP** + **8 CNP** (3 demo + 4 monitoring + 1 transit) + **1 KCNP** (`admin-deny-cloud-metadata`). For the detailed breakdown, see `master-design.md` §8.5. The install template (cluster setup) and the application layer (deployed CNPs) are counted together; install-only activity with default flags is separate (§8.5). The table below is a known/example subset, not an exhaustive list:

| Policy | Scope | Description | Cloud Equivalent |
|--------|-------|----------|---------------|
| **global-default-deny** | Cluster-wide (CCNP) | Denies all traffic by default | Security Group default deny |
| **global-allow-dns** | Cluster-wide (CCNP) | Allows access to kube-apiserver / DNS | VPC endpoint policy |
| **global-allow-gateway-ingress** | Cluster-wide (CCNP) | Ingress traffic from Gateway to pods | ALB target group rules |
| **global-allow-gateway-world-ingress** | Cluster-wide (CCNP) | Inbound 80/443 from the outside world to the Gateway | ALB/NLB internet-facing listener |
| **cilium-allow-cluster-egress** | Pod-level (KCNP) | Pod-to-cluster-wide egress (optional) | VPC peering rules |
| **cilium-allow-cidr-egress** | Namespace (CNP) | Egress from pod to specific CIDRs (optional) | NACL rules |
| **cilium-ns-isolation** | Namespace (CNP) | Namespace isolation (optional) | VPC Security Groups per namespace |
| **cilium-allow-fqdn-egress** | Namespace (CNP) | FQDN-based egress (optional) | WAF + DNS filtering |

---

## 5. Maintenance Scripts

| Script | Task |
|--------|-------|
| **backup-full.sh** | Full disk image via vzdump (weekly; 28 days flat + tier 3 weekly / 3 months) |
| **backup-quick.sh** | ZFS snapshot (before upgrades, last 3 snapshots) |
| **backup-etcd.sh** | etcd snapshot → restic (Garage2); 6 times per day, keep-last 12/3/3 |
| **backup-openbao.sh** | OpenBao raft snapshot → restic (Garage2); 6 times per day, keep-last 3/3/3 |
| **prune-s3.sh** | Legacy flat S3 cleanup (manual; not used in the restic architecture) |
| **healthcheck.sh** | Backup freshness check (`restore.sh health` calls it) |
| **restore.sh** | Main menu — choose which component to recover |
| **restore-vm.sh** | Recover VM/LXC from vzdump backup |
| **restore-etcd.sh** | Download etcd snapshot from restic (fallback: legacy S3) + load into the K8s control plane |
| **restore-openbao.sh** | Restore OpenBao raft snapshot (OpenBao runs in an LXC) |

---

## 6. Data Layer

| Cloud-in-Lab | AWS Equivalent | Azure Equivalent | GCP Equivalent | Mechanism |
|----------|-------------|---------------|-------------|---------------|
| **GarageHQ** | S3 | Blob Storage | Cloud Storage | Object storage (S3 API) |
| **State encryption** | S3 client-side encryption (PBKDF2/AES-GCM-like CSE) | Blob client-side encryption | CSEK / CMEK | Local encryption before writing to S3 |
| **etcd backup** | etcd (included in EKS) | etcd (included in AKS) | etcd (included in GKE) | K8s state backup |

---

## 7. Operations Layer

| Cloud-in-Lab | AWS Equivalent | Azure Equivalent | GCP Equivalent | Mechanism |
|----------|-------------|---------------|-------------|---------------|
| **vzdump backup** | EBS Snapshots + AMI | Azure Disk Snapshots | Persistent Disk Snapshots | Full disk backup |
| **ZFS snapshot** | EBS Fast Snapshot Restore | — | — | Fast snapshot |
| **etcd snapshot** | etcd backup (AWS-native) | etcd backup | etcd backup | K8s state recovery |
| **restore.sh** | AWS Backup + CloudFormation rollback | Azure Backup + ARM rollback | GCP Backup + Deployment rollback | Menu-driven recovery |

---

## 8. Application Layer (k8s-apps)

Application rollout and removal are executed declaratively through Ansible (`k8s_apps.yml` / `k8s_apps_remove.yml`); this is scoped separately from the `k8s.yml` infrastructure playbook. The source of truth is `ansible/inventory/group_vars/all/k8s_apps.yml` (SSOT).

| Cloud-in-Lab | AWS Equivalent | Azure Equivalent | GCP Equivalent | Mechanism |
|----------|-------------|---------------|-------------|---------------|
| **`app-deploy` (templated, `apps[]`)** | CloudFormation / CDK deploy | ARM/Bicep deploy | Deployment Manager / Config Controller | Pure K8s manifest render + apply with Jinja2 |
| **`chart-deploy` (charted, Helm)** | EKS Add-ons / Helm release | AKS extension / Helm | GKE Marketplace / Helm | Helm release with `chart_defaults` deep-merge |
| **`app-remove` (`state: absent`, `-e remove=`)** | CloudFormation stack delete + cascade prune | Resource group cascade delete | Deployment resource cleanup | Clean teardown including Certificate, ListenerSet, CNP, SPC |
| **`enable` vs `state: absent`** | Stack update: retain vs delete | Policy assignment disable | Config sync pause | The flag selects the play; live state is read from the cluster |
| **ServiceMonitor (`prometheus-scrape`)** | Amazon Managed Prometheus scrape configs | Azure Monitor Prometheus scraping | Managed Prometheus / PodMonitoring | Automatic target discovery via CRD |
| **ListenerSet + dedicated TLS** | ALB listener + ACM cert (SNI) | App Gateway host name binding | Managed cert + LB | `tls.mode: dedicated` + `use_base_domain: false` → prerequisite step |
| **Fail-fast (assert + render)** | CloudFormation change-set validate | What-if deployment | Preview deploy | Fails fast on validation errors prior to `kubectl apply` |

Selected run: `-e app_filter=<name>` (app), `-e chart_filter=<name>` (Helm chart), `-e remove=<name>` (removal). For the 17-step deploy flow and kind matrix, see `docs/tr/architecture/k8s-apps-design.md`.

---

## 9. Cloud API Emulation (Floci & Laws)

This need is met by two local emulators: **Floci** (VM) and **Laws** (LXC). The two are independent of each other and can also be run at the same time when needed — neither excludes the other; which one(s) to `enable` is chosen entirely according to need (see master-design.md §6).

Both projects position themselves on their GitHub pages with a similar motivation: when LocalStack's Community edition moved to mandatory account/token in March 2026 and froze security updates, Floci emerged as an alternative requiring no account or token in response to this change. Laws is similarly a lightweight AWS emulator that runs as a single Rust binary and requires no Docker or Python runtime.

| Feature | Laws | Floci |
|---|---|---|
| Language/Runtime | Rust, single binary (~24 MB) | Java/Quarkus + GraalVM |
| Number of services | 184 listed, most are in-memory stubs | 130 supported services |
| Services requiring a real engine | None — all stubs | Lambda/RDS/Neptune/DocumentDB/MSK/MQ/ECS/EC2/EKS/MWAA/CodeBuild/OpenSearch/ElastiCache → real Docker container |
| Startup / RAM | ~1 ms / ~2 MB | ~24 ms / ~13 MB |
| LocalStack compatibility | Partial (port 4566) | Full drop-in |
| When to prefer | Simple CI/CD, SDK smoke tests | Realistic scenarios such as running Lambda, connecting to a real RDS, provisioning EC2 |

> **Scope note — not just AWS:** The Floci ecosystem extends beyond AWS as well; a sibling project called floci-az emulates Azure services with the same lightweight architecture. This shows that the emulation layer in the project can later be extended to non-AWS scenarios — the fact that only AWS emulation is currently used in Cloud-in-Lab does not mean the architecture is limited to it.

**The logic behind it — the Bootstrap Problem:** When an IaC project is started in the cloud, the state backend (S3 bucket, IAM role) is usually set up on top of an account that already exists, so the bootstrap step is relatively small. In this project, however, GarageHQ itself, which will store the state, cannot be provisioned with Tofu (`tofu init` already carries a remote state dependency); therefore bootstrap is orchestrated entirely by the `chef.sh` script with a single command: SSH check → Alpine template check → find an empty Container ID → Garage LXC setup (`setup-garage-lxc.sh` is run remotely) → verification → credential generation → backend file generation. This is the practical workaround used in this homelab to solve the classic chicken-and-egg problem where IaC cannot provision its own state storage.

---

## 10. Additional Applicable Features

The following features can be implemented with this structure, but have not yet been implemented.

| Feature | How Can It Be Implemented? | Equivalent |
|---------|----------------------|---------|
| **Multi-region** | By creating VMs/LXCs at different physical locations with a Proxmox cluster (multiple nodes) | AWS Multi-AZ, Azure Availability Zones |
| **Auto-scaling** | Dynamic VM addition/removal with the Tofu `count` parameter (manually triggered) | EC2 Auto Scaling Group |
| **HA (High Availability)** | Replicating master nodes with a Proxmox cluster | EKS Multi-Master, AKS HA |
| **Load Balancing** | Cilium L2 Announcement + Gateway API | ALB/NLB, Azure Load Balancer |
| **Service Mesh** | Cilium service mesh (eBPF-based) | Istio, App Mesh, Linkerd |
| **GitOps** | K8s application management with ArgoCD or Flux | AWS CodeDeploy, Azure DevOps |
| **CI/CD Pipeline** | Integration with Jenkins or GitHub Actions | AWS CodePipeline, GitHub Actions |

---

## 11. Cloud Comparison Matrix

This matrix shows which cloud layers Cloud-in-Lab implements/can implement. The schema is as in §8: AWS / Azure / GCP columns are separate, plus implementation level and Cloud-in-Lab component + note. For OpenBao engine/profile depth, see §3 and `docs/tr/openbao/openbao-architecture-guide.md` §1.5.

| Cloud Layer | AWS Equivalent | Azure Equivalent | GCP Equivalent | Implementation | Cloud-in-Lab Component | Mechanism / Note |
|---|---|---|---|---|---|---|
| **Compute (EC2/VM)** | EC2 / Launch Template | Virtual Machines / VMSS | Compute Engine | ✅ High | Tofu VM module | Golden image clone (template 9000), full lifecycle, cloud-init |
| **Container (Fargate)** | Fargate / ECS Task | Container Instances / ACI | Cloud Run | ✅ High | Tofu LXC module | Lightweight, unprivileged, nesting; OpenBao and emulator LXCs |
| **Orchestration (EKS)** | EKS | AKS | GKE | ✅ High | kubeadm + Cilium 1.20.1 | Full K8s 1.36.2 cluster; no kube-proxy, eBPF datapath |
| **IaC (Infrastructure as Code)** | Terraform Cloud / CloudFormation | Bicep / ARM | Deployment Manager | ✅ High | OpenTofu 1.8+ | Declarative IaC; state lock + Garage S3 backend; separate prefix per stack |
| **Config Management** | Systems Manager / Ansible AAP | Ansible / DSC | OS Config / Ansible | ✅ High | Ansible 2.16+ | Agentless SSH; playbook/role layer; staged with `--tags` |
| **Container Registry** | ECR | ACR | Artifact Registry / GCR | ✅ High | Docker Hub / Harbor (optional) | Image/chart supply; Harbor optional Helm inside the cluster |
| **Identity & Access** | IAM + IRSA / STS | Entra ID + Managed Identity | IAM + Workload Identity | ✅ High | SA-JWT + AppRole + K8s RBAC | Pod: `auth/kubernetes`; machine/ops: AppRole; 15 ClusterRole templates |
| **Network (VPC)** | VPC + SG + NACL | VNet + NSG | VPC + firewall | ✅ High | Cilium CNI + Gateway API | eBPF-based; default-deny; L2 announcement (`lb_ip_pool`) |
| **Ingress / LB + TLS** | ALB/NLB + ACM | App Gateway + TLS | HTTPS LB + cert | ✅ High | Gateway API 1.6.1 + Cilium Envoy | L4/L7 + TLS termination; shared and dedicated (ListenerSet) |
| **Secret (Secrets Manager)** | Secrets Manager + STS | Key Vault | Secret Manager | ✅ High | OpenBao KV v2 + CSI | PKI + Transit + AppRole + KV + Database + Audit; no copy to etcd |
| **KMS / Envelope Encryption** | KMS + DKE | Key Vault Keys | Cloud KMS | ✅ High | OpenBao Transit (`aes256-gcm96`) | DEK/KEK; application + etcd envelope; keys cannot be exported |
| **PKI / Private CA** | ACM Private PCA (root + sub CA) | Key Vault Certificates (root + intermediate) | Private CA Service | ✅ High | OpenBao PKI (`pki/` + `pki-int/`) | Root EC P-384 10 years; Intermediate 90 days; signing is narrow via `pki-int/sign/*` (guide §1.5 — PKI Engine Private CA) |
| **PKI / K8s consumption (cert-manager)** | ACM + cert-manager | Key Vault + akv2k8s | CAS + cert-manager | ✅ High | cert-manager 1.21.1 + AppRole Issuer | Gateway TLS (shared) + per-app dedicated. **`pki-signer`** signing 1h/24h; **`pki-manager`** `roles/dedicated-*` CRUD 15m/1h, `allow_any_name` forbidden (guide §1.5 — PKI Engine K8s consumption) |
| **Storage (S3)** | S3 | Blob Storage | Cloud Storage | ✅ High | GarageHQ | S3 API compatible; tofu state locally PBKDF2/AES-GCM encrypted |
| **Security (IAM/SG)** | IAM + Security Groups | RBAC + NSG | IAM + VPC firewall | ✅ High | RBAC + Cilium Policy + Proxmox Token | 15 ClusterRole (9+5+1 loop); 29 Cilium policies (20 CCNP + 8 CNP + 1 KCNP) |
| **Audit / CloudTrail** | CloudTrail | Activity Log / Monitor | Cloud Audit Logs | 🟡 Partial | OpenBao audit device | Local `file` + SHA-256 HMAC active; no centralized log forwarding |
| **Monitoring** | CloudWatch / AMP | Azure Monitor | Cloud Monitoring | ✅ High | kube-prometheus-stack | Prometheus + Grafana; 25/25 targets UP; ServiceMonitor scrape |
| **Telemetry (exporter)** | CloudWatch metrics | Azure Monitor metrics | Cloud Ops metrics | ✅ High | openbao-metrics-exporter | Python stdlib 3 loops; sealed → `/v1/sys/health` 503 fallback (guide §10) |
| **Network Observability (Flow Logs)** | VPC Flow Logs | NSG Flow Logs | VPC Flow Logs | ✅ High | Hubble (relay + UI) | eBPF flow/service map; policy allow-deny trace (k8s-design §3.3) |
| **Alerting (Alarms)** | CloudWatch Alarms | Azure Alerts | Cloud Monitoring alerting | ✅ High | Alertmanager + PrometheusRule | OpenBao 15 rules (4C+11W, `openbao-alerts.yaml`); openbao §10.5 |
| **Application Lifecycle (CD)** | CloudFormation / CodeDeploy | ARM deploy / DevOps | Deployment Manager | ✅ High | app-deploy / chart-deploy / app-remove | Declarative deploy + clean teardown (§8); `-e app_filter/chart_filter/remove` |
| **Backup** | AWS Backup + EBS snapshots | Azure Backup | GCP Backup | ✅ High | vzdump + restic | VM/LXC (vzdump) + etcd snapshot + OpenBao raft → restic (Garage2, bucket=repo); keep-last retention |
| **AWS API Emulation** | — (real AWS account) | — | — | ✅ High | Floci / Laws | Development/test without a real account (§9) |
| **Auto-scaling** | ASG | VMSS | MIG | ⚠️ Applicable | Tofu count + manual trigger | Not yet implemented |
| **HA (High Availability)** | Multi-AZ / ELB | Availability Zones | Regional HA | ⚠️ Applicable | Proxmox cluster | Not yet implemented; single-node SPOF accepted |
| **Multi-region** | Multi-region | Paired regions | Multi-region | ⚠️ Applicable | Proxmox cluster (multiple nodes) | Not yet implemented |

---

