# Bulut Karşılıkları ve Benzeri Uygulama Örnekleri

> Sürümler: K8s 1.36.2 · Cilium 1.20.1 · Gateway API 1.6.1 · OpenBao 2.6.2 · cert-manager 1.21.1 · Helm 4.2.4 · kube-prometheus-stack 88.6.1 · Proxmox BPG Provider ~> 0.78 · GarageHQ 2.1.0

Bu belge, Cloud-in-Lab projesindeki bileşenlerin bulut ortamlarında benzer karşılıklarını ve bu projede nelerin yapılabileceğini gösterir.

---

## Temel Yaklaşım

Cloud-in-Lab, homelab'da bulut altyapısının benzer mimari kalıplarını uygulamak için kullanılır. Amaç, aynı ilkeleri daha düşük maliyetle test etmek ya da öğrenme ortamı sağlamaktır. Bu belge bir "bulutla yarışma" tablosu değildir — buluttaki bir mekanizmanın burada hangi araçla, hangi mantıkla yeniden kurulduğunu gösterir.

---

## 1. Altyapı Katmanı (OpenTofu ile Provisioning)

OpenTofu, Proxmox'ta VM ve LXC oluşturur. Bu yapı, bulut ortamlarındaki benzer işlemlere karşılık gelebilir.

| Cloud-in-Lab | AWS Benzeri | Azure Benzeri | GCP Benzeri | Ne Yapılıyor? |
|----------|-------------|---------------|-------------|---------------|
| **VM modülü (clone)** | EC2 Launch Template + AMI | VMSS + Custom Image | Compute Engine + Custom Image | Golden image'dan VM klonlama |
| **LXC modülü** | Fargate / ECS Task | Container Instances | Cloud Run | Hafif container tabanlı servis |
| **common.tfvars** | Terraform Workspace | Subscription/Resource Group | Project/Zone | Ortam bazlı ortak konfigürasyon |
| **node_pools map** | EKS Managed Node Groups | AKS Node Pools | GKE Node Pools | Dinamik VM havuzları (for_each) |
| **cidrhost() IP** | VPC Static IP / ENI | VNet Static IP | Static Internal IP | Otomatik IP adresleme |
| **cloud-init (initialization)** | EC2 user_data + SSH key pair | Custom Data + SSH | Metadata + SSH | İlk kurulum konfigürasyonu |
| **template_vm_id (9000)** | AMI ID | Gallery Image ID | Family Image | Paylaşılan golden image |

### Proje Kalıpları

**VM Kalıbı** (ağır işler için — K8s, CI runner):
```
Template (ID 9000) → full clone → guest agent → data disk (opsiyonel)
```
Benzer uygulama: `aws ec2 run-instances --launch-template ... --image-id ami-xxx`

**LXC Kalıbı** (hafif servisler için — OpenBao, LocalStack):
```
LXC Template (.tar.zst) → container create → unprivileged + nesting
```
Benzer uygulama: `aws ecs run-task --launch-type FARGATE` (task definition'ı önceden tanımlı bir image'e işaret eder)

### Proxmox Ön Hazırlık Script'leri

Tofu çalışmadan önce Proxmox tarafında üç şeyin hazır olması gerekir; bunun için `scripts/proxmox/` altındaki script'ler kullanılır. Tofu'nun kendisi bunlardan hiçbirini yapmaz, sadece çıktılarını (`common.tfvars` içindeki değerleri ve golden image'ı) tüketir:

| Script | Ne Yapar | Bulut Benzeri |
|---|---|---|
| `discover-pve.sh` | Proxmox ağ/storage/mevcut VM bilgilerini toplar (`pve-discovered.txt`) | `aws ec2 describe-vpcs` / `describe-subnets` gibi keşif API çağrıları |
| `setup-proxmox-token.sh` | Rol + kullanıcı oluşturup API token üretir | IAM rol + kullanıcı + access key oluşturma (`create-role` / `create-user` / `create-access-key`) |
| `create-vm-template.sh` | Cloud-image indirip checksum doğrulayarak parametrik VM template üretir — `--distro`, `--version`, `--cores`, `--memory`, `--bios` gibi parametrelerle Ubuntu/Debian/Rocky/AlmaLinux'un istenen kombinasyonu, `--dry-run` ile önizleme, hata durumunda otomatik temizlik (`trap cleanup`) | EC2 Image Builder / Packer ile AMI üretme pipeline'ı |

---

## 2. Platform Katmanı (Ansible ile Konfigürasyon)

Ansible, Tofu'nun açtığı makinelerin içine yazılım kurar. Bu yapı, bulut ortamlarındaki benzer konfigürasyon süreçlerine karşılık gelebilir.

| Cloud-in-Lab | AWS Benzeri | Azure Benzeri | GCP Benzeri | Ne Yapılıyor? |
|----------|-------------|---------------|-------------|---------------|
| **K8s Cluster** | EKS | AKS | GKE | Container orkestrasyon |
| **Cilium CNI** | VPC CNI + Calico | Azure CNI + Calico | Dataplane V2 | Ağ yönetimi + network policy |
| **Gateway API + ListenerSet** | ALB/NLB + ACM cert (+ AWS Gateway API Controller) | App Gateway + Traffic Manager | Cloud Load Balancer | Ingress/egress; dedicated TLS'de ListenerSet |
| **OpenBao** | KMS + Secrets Manager + ACM + STS | Key Vault + Managed Identity | Cloud KMS + Secret Manager + IAM | Secret + PKI + KMS + credential yönetimi |
| **cert-manager** | ACM (kısmen) | App Gateway Certs | Managed Certificates | Sertifika yaşam döngüsü |
| **CSI Driver** | Secrets Manager CSI | Key Vault CSI | Secret Manager CSI | Secret'ları pod'lara mount |
| **RBAC** | IAM Roles + Policies + STS AssumeRole | Azure AD Roles + Managed Identity | IAM Roles + Service Accounts | Rol tabanlı erişim |
| **Workload identity (SA-JWT)** | IRSA / EKS Pod Identity | Workload Identity + Managed Identity | Workload Identity Federation | Pod: SA-JWT; K8s dışı: AppRole |
| **Network Policies** | Security Groups + NACLs + WAF | NSGs + ASGs + Firewall | VPC Firewall Rules + Cloud Armor | Ağ filtreleme |

**Cilium/eBPF'in arkasındaki mantık:** Bulut sağlayıcılarında VPC Security Group / NACL kuralları IP ve port üzerinden çalışır — bir pod'un IP'si değiştiğinde kuralın yeniden hesaplanması gerekir. Cilium ise eBPF ile kimlik (identity) tabanlı çalışır: kurallar pod IP'sine değil, pod'un etiketlerinden türetilen bir kimliğe bağlanır, bu yüzden pod yeniden oluşsa/IP değişse bile politika geçerliliğini korur. Bu, AWS'nin VPC CNI + Security Group modelinden temelde farklı bir yaklaşımdır ve projedeki default-deny/identity-based selector deseni bu farkın doğrudan sonucu.

---

## 3. OpenBao — Kapsamlı Yetenekler

OpenBao sadece secret yönetimi değil, birden fazla altyapı hizmetini tek çatı altında toplar.

| Yetenek | Açıklama | Bulut Benzeri |
|---------|----------|---------------|
| **KV v2** | Versioned key-value secret depolama | AWS Secrets Manager, Azure Key Vault |
| **PKI Engine** | Root CA + Intermediate CA üretimi, sertifika imzalama; base-domain dışı isteklerde `dedicated-pki-domains.yml` ile dinamik rol + ClusterIssuer | ACM Private CA / PCA (domain-constrained sub CA), Azure CA, step-ca |
| **Transit Engine** | Envelope encryption (`aes256-gcm96`); DEK/KEK ayrımı | AWS KMS, Azure Key Vault Keys, GCP Cloud KMS |
| **AppRole Auth** | Machine identity (service account benzeri) | IAM Roles, Azure Managed Identity |
| **Kubernetes Auth (SA-JWT)** | Pod ServiceAccount JWT ile CSI girişi | IRSA / Workload Identity |
| **Database Secrets Engine** | Dinamik credential üretimi (TTL'li) | RDS IAM Authentication, Azure AD Auth |
| **Static Secrets** | Kalıcı secret kayıtları | Secrets Manager, Key Vault |
| **Audit Log** | Tüm API çağrılarının kaydı | CloudTrail, Azure Activity Log |
| **Unseal Mekanizması** | Threshold-based unseal (3/5 key) | HSM-backed KMS |
| **CSI Provider** | K8s pod'larının OpenBao'ya bağlanması | Secrets Store CSI Driver |

**AppRole'ün arkasındaki mantık:** Cloud'da bir EC2 instance'ın IAM Role alması, instance metadata servisi üzerinden otomatik ve örtük olur — instance'ın kimliği, bulut sağlayıcının kendisi tarafından doğrulanır. OpenBao K8s dışında (ayrı bir LXC'de) çalıştığı için bu örtük doğrulama mekanizması yoktur; bunun yerine AppRole ile açık bir `role_id` + `secret_id` çifti kullanılır — makine kimliğini bulut sağlayıcı değil, tanımlanan politika doğrular. Bu, cloud'un instance identity için native olarak sağladığı mekanizmanın on-prem ortamda nasıl yeniden kurulduğunu gösteren bir örnektir.

### 3.1 RBAC / Authorization Detayı (openbao-rbac.md §7)

RBAC katmanının mekanizma-hasar karşılıkları — planın §1 bölümünün bu dokümana taşınan halidir:

| OpenBao | AWS IAM karşılığı | Mekanizma |
|---|---|---|
| AppRole | IAM Role (machine identity) | `role_id`+`secret_id` = `AssumeRole` |
| **Kubernetes auth (SA-JWT)** | **IRSA / EKS Pod Identity** (Workload Identity) | Pod SA JWT ↔ `auth/kubernetes`; CSI path |
| Policy (HCL) | IAM Policy (JSON) | Path/capability tabanlı |
| **Identity templating** | **IAM Policy Variables** | `{{identity...}}` ↔ `${aws:PrincipalTag/...}` |
| Entity/Group | IAM Group | Politika toplu atama |
| `secret_id` wrapping | STS `AssumeRole` + external ID | Tek kullanımlık, kısa TTL |
| `token_bound_cidrs` | IAM Condition `aws:SourceIp` | Ağ seviyesi kısıt |
| Control Groups (2.7, henüz yok) | IAM Permission Boundary + onay akışı | İnsan-in-the-loop |

> **Not (root kullanımı):** root token'ın yanlışlıkla veya başka bir şekilde silinmesi,ele geçirilmesi vb durumlara karşı root'un günlük işlemlerde kullanılmaması ve yalnızca break-glass için saklanır. root yalnız bir kez `rbac-platform.yml` bootstrap'ında kullanılır; sonrasında tüm rutin işler `ops-admin` (P4) token'ıyla yürür — ayrıntı: [`openbao-rbac.md`](openbao/openbao-rbac.md) §6.2.

---

## 4. Güvenlik Katmanı

### 4.1 Kubernetes RBAC

| Bileşen | Adet | Açıklama | Bulut Benzeri |
|---------|------|----------|---------------|
| **ClusterRole şablonu** | 15 | 9 custom (pod-reader, pod-log-reader, workload-viewer, full-viewer, pod-operator, workload-operator, config-editor, deployer, monitoring-reader) + 5 aggregated (aggregated-viewer, aggregated-developer, aggregated-deployer, aggregated-admin, aggregated-monitoring) + 1 envanter loop (`custom_cluster_roles`) | IAM Custom Roles |
| **Varsayılan Kubeconfig** | 5 | `admin` (tam yetkili) + `deployer`, `developer`, `monitoring`, `viewer` (rol bazlı) — `gen-kubeconfig.yml` playbook'u ile üretilir | STS AssumeRole with profile |
| **Namespace Isolation** | 1 | kubeconfig-sa (tüm SA'lar bu namespace'de) | VPC per-team isolation |

> **Not:** Varsayılan olarak 5 kubeconfig üretilir; `gen-kubeconfig.yml` ile istenen rol kombinasyonunda özel kubeconfig'ler de üretilebilir — sabit 5 ile sınırlı değildir. Şablon toplamı 15'tir (master-design §8.5); sabit isimli 14 + envanter loop.

### 4.2 Cilium Network Policies

Test edilmiş aktif politika sayısı toplamda **29**'tur: **20 CCNP** + **8 CNP** (3 demo + 4 monitoring + 1 transit) + **1 KCNP** (`admin-deny-cloud-metadata`). Detaylı dağılım için bkz. `master-design.md` §8.5. Install şablonu (cluster kurulumu) ile uygulama katmanı (deploy edilen CNP'ler) birlikte sayılır; default bayraklarla install-only aktiflik ayrıdır (§8.5). Aşağıdaki tablo bilinen/örnek bir alt kümesidir, kapsayıcı liste değildir:

| Politika | Scope | Açıklama | Bulut Benzeri |
|--------|-------|----------|---------------|
| **global-default-deny** | Cluster-wide (CCNP) | Varsayılan tüm trafiği engelle | Security Group default deny |
| **global-allow-dns** | Cluster-wide (CCNP) | kube-apiserver / DNS erişimine izin ver | VPC endpoint policy |
| **global-allow-gateway-ingress** | Cluster-wide (CCNP) | Gateway'den pod'lara ingress trafiği | ALB target group rules |
| **global-allow-gateway-world-ingress** | Cluster-wide (CCNP) | Dış dünyadan Gateway'e 80/443 girişi | ALB/NLB internet-facing listener |
| **cilium-allow-cluster-egress** | Pod-level (KCNP) | Pod'dan cluster-wide egress (opsiyonel) | VPC peering rules |
| **cilium-allow-cidr-egress** | Namespace (CNP) | Pod'dan belirli CIDR'lere egress (opsiyonel) | NACL rules |
| **cilium-ns-isolation** | Namespace (CNP) | Namespace izolasyonu (opsiyonel) | VPC Security Groups per namespace |
| **cilium-allow-fqdn-egress** | Namespace (CNP) | FQDN bazlı egress (opsiyonel) | WAF + DNS filtering |

---

## 5. Maintenance Scriptleri

| Script | Görev |
|--------|-------|
| **backup-full.sh** | vzdump ile tam disk görüntüsü (haftalık; 28 gün flat + tier 3 hafta / 3 ay) |
| **backup-quick.sh** | ZFS anlık snapshot (upgrade öncesi, son 3 snapshot) |
| **backup-etcd.sh** | etcd snapshot → restic (Garage2); günde 6 kez, keep-last 12/3/3 |
| **backup-openbao.sh** | OpenBao raft snapshot → restic (Garage2); günde 6 kez, keep-last 3/3/3 |
| **prune-s3.sh** | Legacy flat S3 temizliği (elle; restic mimarisinde kullanılmaz) |
| **healthcheck.sh** | Yedek tazelik kontrolü (`restore.sh health` çağırır) |
| **restore.sh** | Ana menü — hangi bileşeni kurtaracağını seç |
| **restore-vm.sh** | vzdump backup'ından VM/LXC kurtarma |
| **restore-etcd.sh** | restic'ten etcd snapshot indir (fallback: legacy S3) + K8s kontrol plânına yükle |
| **restore-openbao.sh** | OpenBao raft snapshot geri yükleme (OpenBao LXC'de çalışır) |

---

## 6. Veri Katmanı

| Cloud-in-Lab | AWS Benzeri | Azure Benzeri | GCP Benzeri | Ne Yapılıyor? |
|----------|-------------|---------------|-------------|---------------|
| **GarageHQ** | S3 | Blob Storage | Cloud Storage | Object storage (S3 API) |
| **State şifreleme** | S3 client-side encryption (PBKDF2/AES-GCM benzeri CSE) | Blob client-side encryption | CSEK / CMEK | S3'e yazılmadan önce yerel şifreleme |
| **etcd backup** | etcd (EKS dahil) | etcd (AKS dahil) | etcd (GKE dahil) | K8s state yedekleme |

---

## 7. Operasyon Katmanı

| Cloud-in-Lab | AWS Benzeri | Azure Benzeri | GCP Benzeri | Ne Yapılıyor? |
|----------|-------------|---------------|-------------|---------------|
| **vzdump backup** | EBS Snapshots + AMI | Azure Disk Snapshots | Persistent Disk Snapshots | Tam disk yedekleme |
| **ZFS snapshot** | EBS Fast Snapshot Restore | — | — | Hızlı anlık görüntü |
| **etcd snapshot** | etcd backup (AWS-native) | etcd backup | etcd backup | K8s state kurtarma |
| **restore.sh** | AWS Backup + CloudFormation rollback | Azure Backup + ARM rollback | GCP Backup + Deployment rollback | Menülü kurtarma |

---

## 8. Uygulama Katmanı (k8s-apps)

Uygulama yayılımı ve kaldırması Ansible (`k8s_apps.yml` / `k8s_apps_remove.yml`) üzerinden deklaratif yürütülür; `k8s.yml` altyapı playbook'undan sınırlıdır. Beyan kaynağı `ansible/inventory/group_vars/all/k8s_apps.yml` (SSOT)'tır.

| Cloud-in-Lab | AWS Benzeri | Azure Benzeri | GCP Benzeri | Ne Yapılıyor? |
|----------|-------------|---------------|-------------|---------------|
| **`app-deploy` (templated, `apps[]`)** | CloudFormation / CDK deploy | ARM/Bicep deploy | Deployment Manager / Config Controller | Jinja2 ile saf K8s manifest render + apply |
| **`chart-deploy` (charted, Helm)** | EKS Add-ons / Helm release | AKS extension / Helm | GKE Marketplace / Helm | `chart_defaults` deep-merge ile Helm release |
| **`app-remove` (`state: absent`, `-e remove=`)** | CloudFormation stack delete + cascade prune | Resource group cascade delete | Deployment resource cleanup | Certificate, ListenerSet, CNP, SPC dahil temiz teardown |
| **`enable` vs `state: absent`** | Stack update: retain vs delete | Policy assignment disable | Config sync pause | Bayrak play'i seçer; canlı durum kümeden okunur |
| **ServiceMonitor (`prometheus-scrape`)** | Amazon Managed Prometheus scrape configs | Azure Monitor Prometheus scraping | Managed Prometheus / PodMonitoring | CRD ile otomatik hedef keşfi |
| **ListenerSet + dedicated TLS** | ALB listener + ACM cert (SNI) | App Gateway host name binding | Managed cert + LB | `tls.mode: dedicated` + `use_base_domain: false` → ön-adım |
| **Fail-fast (assert + render)** | CloudFormation change-set validate | What-if deployment | Preview deploy | `kubectl apply` öncesi girdi/sablon durdurma |

Seçili çalışma: `-e app_filter=<ad>` (app), `-e chart_filter=<ad>` (Helm chart), `-e remove=<ad>` (kaldırma). 17 adımlı deploy akışı ve kind matrisi için bkz. `docs/tr/architecture/k8s-apps-design.md`.

---

## 9. Cloud API Emülasyonu (Floci & Laws)

Bu ihtiyaç, iki yerel emülatörle karşılanır: **Floci** (VM) ve **Laws** (LXC). İkisi birbirinden bağımsızdır ve gerektiğinde aynı anda da çalıştırılabilir — biri diğerini dışlamaz, hangisinin/hangilerinin `enable` edileceği tamamen ihtiyaca göre seçilir (bkz. master-design.md §6).

Her iki proje de kendi GitHub sayfalarında benzer bir motivasyonla konumlanıyor: LocalStack'in Community sürümü Mart 2026'da hesap/token zorunluluğuna geçip güvenlik güncellemelerini dondurunca, Floci bu değişikliğe karşı hesap veya token gerektirmeyen bir alternatif olarak öne çıktı. Laws da benzer şekilde, Docker veya Python çalışma zamanı gerektirmeyen, tek bir Rust binary'si olarak çalışan hafif bir AWS emülatörü.

| Özellik | Laws | Floci |
|---|---|---|
| Dil/Runtime | Rust, tek binary (~24 MB) | Java/Quarkus + GraalVM |
| Servis sayısı | 184 listelenen, çoğu in-memory stub | 130 desteklenen servis |
| Gerçek engine gerektiren servisler | Yok — hepsi stub | Lambda/RDS/Neptune/DocumentDB/MSK/MQ/ECS/EC2/EKS/MWAA/CodeBuild/OpenSearch/ElastiCache → gerçek Docker container |
| Startup / RAM | ~1 ms / ~2 MB | ~24 ms / ~13 MB |
| LocalStack uyumu | Kısmi (port 4566) | Tam drop-in |
| Ne zaman tercih edilir | Basit CI/CD, SDK smoke test | Lambda çalıştırma, RDS'e gerçek bağlantı, EC2 provision gibi gerçekçi senaryolar |

> **Kapsam notu — sadece AWS değil:** Floci ekosistemi AWS'nin dışına da taşıyor; floci-az adlı kardeş proje aynı hafif mimariyle Azure servislerini emüle ediyor. Bu, projedeki emülasyon katmanının ileride AWS dışı senaryolara da genişletilebilir olduğunu gösteriyor — şu an Cloud-in-Lab'de sadece AWS emülasyonu kullanılıyor olması, mimarinin buna sınırlı olduğu anlamına gelmiyor.

**Arkasındaki mantık — Bootstrap Problemi:** Cloud'da bir IaC projesi başlatıldığında state backend'i (S3 bucket, IAM rol) genelde zaten var olan bir hesabın üzerine kurulur, bootstrap adımı görece küçüktür. Bu projede ise state'i saklayacak GarageHQ'nun kendisi Tofu ile açılamaz (`tofu init` zaten bir remote state bağımlılığı taşır); bu yüzden bootstrap tamamen `chef.sh` script'i tarafından tek komutla orkestre edilir: SSH kontrolü → Alpine template kontrolü → boş Container ID bulma → Garage LXC kurulumu (`setup-garage-lxc.sh` uzaktan çalıştırılır) → doğrulama → credential üretimi → backend dosyası üretimi. Bu, IaC'nin kendi state altyapısını IaC ile açamaması (chicken-egg problemi) için homelab'de izlenen somut çözümdür.

---

## 10. Uygulanabilir Ek Özellikler

Aşağıdaki özellikler bu yapıyla uygulanabilir, ancak henüz uygulanmamıştır.

| Özellik | Nasıl Uygulanabilir? | Benzeri |
|---------|----------------------|---------|
| **Multi-region** | Proxmox cluster (birden fazla node) ile farklı fiziksel konumlarda VM/LXC oluşturarak | AWS Multi-AZ, Azure Availability Zones |
| **Auto-scaling** | Tofu `count` parametresi ile dinamik VM ekleme/çıkarma (manuel tetiklemeli) | EC2 Auto Scaling Group |
| **HA (Yüksek Erişilebilirlik)** | Proxmox cluster ile master node çoğaltma | EKS Multi-Master, AKS HA |
| **Load Balancing** | Cilium L2 Announcement + Gateway API | ALB/NLB, Azure Load Balancer |
| **Service Mesh** | Cilium service mesh (eBPF tabanlı) | Istio, App Mesh, Linkerd |
| **GitOps** | ArgoCD veya Flux ile K8s uygulama yönetimi | AWS CodeDeploy, Azure DevOps |
| **CI/CD Pipeline** | Jenkins veya GitHub Actions ile entegrasyon | AWS CodePipeline, GitHub Actions |

---

## 11. Bulut Karşılaştırma Matrisi

Bu matris, Cloud-in-Lab’in hangi cloud katmanlarını uyguladığını/uygulayabileceğini gösterir. Şema §8 gibidir: AWS / Azure / GCP sütunları ayrı, ayrıca uygulama derecesi ve Cloud-in-Lab karşılığı + not. OpenBao motor/profil derinliği için §3 ve `docs/tr/openbao/openbao-architecture-guide.md` §1.5.

| Cloud Katmanı | AWS Benzeri | Azure Benzeri | GCP Benzeri | Uygulama | Cloud-in-Lab Bileşeni | Ne Yapılıyor? / Not |
|---|---|---|---|---|---|---|
| **Compute (EC2/VM)** | EC2 / Launch Template | Virtual Machines / VMSS | Compute Engine | ✅ Yüksek | Tofu VM modülü | Golden image clone (template 9000), full lifecycle, cloud-init |
| **Container (Fargate)** | Fargate / ECS Task | Container Instances / ACI | Cloud Run | ✅ Yüksek | Tofu LXC modülü | Hafif, unprivileged, nesting; OpenBao ve emülatör LXC’leri |
| **Orkestrasyon (EKS)** | EKS | AKS | GKE | ✅ Yüksek | kubeadm + Cilium 1.20.1 | Full K8s 1.36.2 cluster; kube-proxy yok, eBPF datapath |
| **IaC (Infrastructure as Code)** | Terraform Cloud / CloudFormation | Bicep / ARM | Deployment Manager | ✅ Yüksek | OpenTofu 1.8+ | Deklaratif IaC; state-lock + Garage S3 backend; stack başına ayrı prefix |
| **Config Management** | Systems Manager / Ansible AAP | Ansible / DSC | OS Config / Ansible | ✅ Yüksek | Ansible 2.16+ | Agentless SSH; playbook/rol katmanı; `--tags` ile aşamalı |
| **Container Registry** | ECR | ACR | Artifact Registry / GCR | ✅ Yüksek | Docker Hub / Harbor (ops.) | Image/chart tedariki; Harbor cluster içine opsiyonel Helm |
| **Identity & Access** | IAM + IRSA / STS | Entra ID + Managed Identity | IAM + Workload Identity | ✅ Yüksek | SA-JWT + AppRole + K8s RBAC | Pod: `auth/kubernetes`; makine/ops: AppRole; 15 ClusterRole şablonu |
| **Ağ (VPC)** | VPC + SG + NACL | VNet + NSG | VPC + firewall | ✅ Yüksek | Cilium CNI + Gateway API | eBPF tabanlı; default-deny; L2 announcement (`lb_ip_pool`) |
| **Ingress / LB + TLS** | ALB/NLB + ACM | App Gateway + TLS | HTTPS LB + cert | ✅ Yüksek | Gateway API 1.6.1 + Cilium Envoy | L4/L7 + TLS termination; paylaşılan ve dedicated (ListenerSet) |
| **Secret (Secrets Manager)** | Secrets Manager + STS | Key Vault | Secret Manager | ✅ Yüksek | OpenBao KV v2 + CSI | PKI + Transit + AppRole + KV + Database + Audit; etcd’ye kopya yok |
| **KMS / Envelope Encryption** | KMS + DKE | Key Vault Keys | Cloud KMS | ✅ Yüksek | OpenBao Transit (`aes256-gcm96`) | DEK/KEK; uygulama + etcd envelope; anahtar export edilemez |
| **PKI / Private CA** | ACM Private PCA (root + sub CA) | Key Vault Certificates (root + intermediate) | Private CA Service | ✅ Yüksek | OpenBao PKI (`pki/` + `pki-int/`) | Root EC P-384 10 yıl; Intermediate 90 gün; imza `pki-int/sign/*` ile dar (rehber §1.5 — PKI Engine Private CA) |
| **PKI / K8s tüketimi (cert-manager)** | ACM + cert-manager | Key Vault + akv2k8s | CAS + cert-manager | ✅ Yüksek | cert-manager 1.21.1 + AppRole Issuer | Gateway TLS (paylaşılan) + per-app dedicated. **`pki-signer`** imza 1sa/24sa; **`pki-manager`** `roles/dedicated-*` CRUD 15dk/1sa, `allow_any_name` yasak (rehber §1.5 — PKI Engine K8s tüketimi) |
| **Depolama (S3)** | S3 | Blob Storage | Cloud Storage | ✅ Yüksek | GarageHQ | S3 API uyumlu; tofu state yerel PBKDF2/AES-GCM şifreli |
| **Güvenlik (IAM/SG)** | IAM + Security Groups | RBAC + NSG | IAM + VPC firewall | ✅ Yüksek | RBAC + Cilium Policy + Proxmox Token | 15 ClusterRole (9+5+1 loop); 29 Cilium policy (20 CCNP + 8 CNP + 1 KCNP) |
| **Audit / CloudTrail** | CloudTrail | Activity Log / Monitor | Cloud Audit Logs | 🟡 Kısmen | OpenBao audit device | Yerel `file` + SHA-256 HMAC aktif; merkezi log aktarımı yok |
| **Monitoring** | CloudWatch / AMP | Azure Monitor | Cloud Monitoring | ✅ Yüksek | kube-prometheus-stack | Prometheus + Grafana; 25/25 target UP; ServiceMonitor scrape |
| **Telemetry (exporter)** | CloudWatch metrics | Azure Monitor metrics | Cloud Ops metrics | ✅ Yüksek | openbao-metrics-exporter | Python stdlib 3 döngü; sealed → `/v1/sys/health` 503 fallback (rehber §10) |
| **Network Observability (Flow Logs)** | VPC Flow Logs | NSG Flow Logs | VPC Flow Logs | ✅ Yüksek | Hubble (relay + UI) | eBPF flow/service map; policy allow-deny izi (k8s-design §3.3) |
| **Alerting (Alarms)** | CloudWatch Alarms | Azure Alerts | Cloud Monitoring alerting | ✅ Yüksek | Alertmanager + PrometheusRule | OpenBao 15 kural (4C+11W, `openbao-alerts.yaml`); openbao §10.5 |
| **Uygulama Lifecycle (CD)** | CloudFormation / CodeDeploy | ARM deploy / DevOps | Deployment Manager | ✅ Yüksek | app-deploy / chart-deploy / app-remove | Deklaratif deploy + temiz teardown (§8); `-e app_filter/chart_filter/remove` |
| **Backup** | AWS Backup + EBS snapshots | Azure Backup | GCP Backup | ✅ Yüksek | vzdump + restic | VM/LXC (vzdump) + etcd snapshot + OpenBao raft → restic (Garage2, kova=repo); keep-last retention |
| **AWS API Emülasyonu** | — (gerçek AWS hesabı) | — | — | ✅ Yüksek | Floci / Laws | Gerçek hesap gerektirmeden geliştirme/test (§9) |
| **Auto-scaling** | ASG | VMSS | MIG | ⚠️ Uygulanabilir | Tofu count + manuel tetikleme | Henüz uygulanmadı |
| **HA (Yüksek Erişilebilirlik)** | Multi-AZ / ELB | Availability Zones | Regional HA | ⚠️ Uygulanabilir | Proxmox cluster | Henüz uygulanmadı; tek düğüm SPOF kabulü |
| **Multi-region** | Multi-region | Paired regions | Multi-region | ⚠️ Uygulanabilir | Proxmox cluster (çoklu node) | Henüz uygulanmadı |
