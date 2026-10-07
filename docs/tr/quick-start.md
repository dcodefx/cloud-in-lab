# quick_start — Sıfırdan Hızlı Kurulum (Tek Node Proxmox VE)

> Bu belge, üzerinde yalnızca Proxmox VE 9 kurulu tek bir makineyi baz alır ve platformu uçtan uca ayağa kaldırmak için gereken adımları sırayla listeler.
> Gerekçe, parametre ayrıntısı ve arka plan için her adımın sonundaki **Detay** bağlantıları kullanılır; burada yalnızca komut zinciri ve beklenen davranış yer alır.

**İki makine modeli:**

| Makine | Rol |
|---|---|
| **Controller** | `tofu` / `ansible` komutlarının koştuğu bilgisayar (bu rehberdeki adımlar burada çalıştırılır) |
| **PVE** | Hedef Proxmox VE makinesi (tek node, 9.x). Tüm PVE scriptleri `root@PVE`'ye parolasız SSH ile bağlanır |

Örnek değerler bu belgede jeneriktir (`192.168.1.x` ailesi, `<PVE_IP>`); CT/VM kimlikleri (Garage **300**, OpenBao **301**, Laws **302**, Garage2 **320**) semboliktir ve istenirse değiştirilir.

---

## Gereksinimler

| Nerede | Gereken |
|---|---|
| Controller | OpenTofu, Ansible, python3 + pyyaml, openssl, curl, bash; `~/.ssh/id_ed25519` anahtar çifti |
| PVE | Proxmox VE 9, `root` için anahtar tabanlı SSH, boş CT/VM ID aralığı, `local` ve `local-lvm` storage'ları (veya eşleniği) |

## Kurulum Haritası

```text
TEMEL AKIŞ
 1. Controller hazırlığı (SSH anahtarı + collections)
 2. PVE keşfi                       → pve-discovered.txt
 3. PVE API token                   → pve-token.txt
 4. VM template                     → template_vm_id
 5. LXC template'leri                (OpenBao + Laws)
 6. tfvars dosyaları                 (klonla GELMEZ, elle doldurulur)
 7. State encryption key             → tofu/secrets/encryption.key
 8. Garage state deposu (CT 300)     → tofu/backends/*.tfbackend
 9. OpenBao LXC (tofu)               → openbao.ini.generated
10. OpenBao kurulumu (ansible)       → init + unseal + PKI bootstrap (otomatik)
11. Kubernetes VM'leri (tofu)        → hosts.ini.generated
12. Kubernetes kurulumu (ansible)    → Cilium + Gateway + CSI + OpenBao entegrasyonu
OPSİYONEL
13. Kubernetes uygulamaları          (prom_stack + apps[])
14. Emülatörler: Floci + Laws
15. Databases + EFK                  (yalnız VM düzeyi — WIP)
16. Yedekleme altyapısı              (Garage2 CT 320 + maintenance)
```

Sıralamanın nedeni: **Garage, tofu state'inin deposudur ve tofu'nun dışında kurulur** (state altyapısı tofu init'ten önce hazır olmalıdır); **OpenBao, K8s'ten önce kurulur** (K8s playbook'unun ön kontrolü `outputs/openbao/openbao-config.json` dosyasını arar).

---

# Temel Akış

## Adım 1 — Controller hazırlığı

**Ne lazım:** PVE root erişimi; controller'da Ansible kurulu.

**Komut:**

```bash
# SSH anahtar çifti (yoksa)
ssh-keygen -t ed25519 -f ~/.ssh/id_ed25519 -N "" -C "tofu-lar@controller"

# Anahtar PVE'ye kopyalanır (tüm PVE scriptleri parolasız root SSH ister)
ssh-copy-id -i ~/.ssh/id_ed25519.pub root@<PVE_IP>

# Ansible collections
cd ansible
ansible-galaxy collection install -r requirements.yml
cd ..
```

**Ne yapacak:** Tüm PVE scriptleri `BatchMode` (parolasız) SSH ile bağlanır; anahtar yoksa scriptler parola sormadan hata verir. `requirements.yml` şu koleksiyonları kurar: `kubernetes.core`, `community.general`, `community.docker`, `ansible.posix`.

**Doğrulama:** `ssh root@<PVE_IP> hostname` parola sormadan döner.

**Detay:** [docs/tr/proxmox/proxmox-preps.md](proxmox/proxmox-preps.md)

## Adım 2 — PVE keşfi

**Ne lazım:** Adım 1.

**Komut:**

```bash
./scripts/proxmox/discover-pve.sh <PVE_IP>
```

**Ne yapacak:** PVE'den `target_node` (PVE hostname), gateway, bridge, subnet, storage listesi ve mevcut VM/LXC envanterini toplar → `scripts/proxmox/pve-discovered.txt`. Bu değerler Adım 6'da tfvars dosyalarına işlenir.

**Doğrulama:** `pve-discovered.txt` içinde node ve storage değerleri görünür.

**Detay:** [docs/tr/proxmox/proxmox-preps.md](proxmox/proxmox-preps.md)

## Adım 3 — PVE API token

**Komut:**

```bash
./scripts/proxmox/setup-proxmox-token.sh --host <PVE_IP>
```

**Ne yapacak:** `TerraformProv` rolü + `terraform-prov@pve` kullanıcısı + `terraform` token'ını açar (PVE 9'da token `--privsep=0` ile oluşturulur) → `scripts/proxmox/pve-token.txt`. Token yalnız bir kez gösterilir; `--force` eski token'ı geçersiz kılar (tofu yapılandırması da güncellenmelidir).

**Doğrulama:** `pve-token.txt` içindeki `proxmox_token = "..."` satırı.

**Detay:** [docs/tr/proxmox/proxmox-preps.md](proxmox/proxmox-preps.md)

## Adım 4 — VM template (K8s / Databases / EFK / Floci VM'leri için)

**Komut:**

```bash
./scripts/proxmox/create-vm-template.sh --host 164.102.98.16 --distro debian --version 13 --use-virt-customize --vmid 9000
./scripts/proxmox/create-vm-template.sh --host 164.102.98.16 --distro ubuntu --version 26.04 --use-virt-customize --vmid 9010
```

**Ne yapacak:** Cloud imajını PVE'ye indirir, doğrular ve QEMU VM template'i açar. Çıktıdaki **VM ID** Adım 6'da `template_vm_id` olarak yazılır. Dev ortamı Debian 13 template'i ile hazırlanmıştır; Ubuntu da kullanılabilir (`--distro ubuntu --version 26.04`). Cloud-init metadata için PVE'de **Snippets** içerikli storage gerekir — eksikse script uyarır (Datacenter → Storage → local → Edit → Content → Snippets).

**Doğrulama:** `ssh root@<PVE_IP> "qm list"` içinde yeni template görünür.

**Detay:** [docs/tr/proxmox/how-to-create-vm-template.md](proxmox/how-to-create-vm-template.md)

## Adım 5 — LXC template'leri (OpenBao + Laws)

**Komut:**

```bash
ssh root@<PVE_IP> "pveam update && pveam download local ubuntu-26.04-standard_26.04-1_amd64.tar.zst"
```

**Ne yapacak:** OpenBao (CT 301) ve Laws (CT 302) LXC'lerinin Ubuntu 26.04 şablonunu `local` storage'a indirir. Garage'ın Alpine şablonunu `chef.sh` kendisi indirir; bu adımda elle bir şey yapılmaz.

**Doğrulama:** `ssh root@<PVE_IP> "pveam list local"` içinde `ubuntu-26.04` görünür.

## Adım 6 — tfvars dosyaları

**Ne lazım:** Adım 2–4 çıktıları.

> **Dikkat:** `tofu/environments/**` altındaki tfvars dosyaları git'e girmez — **klonla gelmez, kurulumda elle oluşturulur.** Aşağıdaki örneklerde Adım 2–3 keşif/token değerleri ve kendi ağ değerleri yazılır.

**Komut / içerik:** `tofu/environments/dev/common.tfvars`:

```hcl
environment    = "dev"
target_node    = "pve"        # pve-discovered.txt: PVE hostname
template_vm_id = 9000         # Adım 4 çıktısındaki gerçek VM ID

base_ip   = "192.168.1.0"     # kendi ağınız (pve-discovered.txt)
ip_mask   = "24"
gateway   = "192.168.1.1"

ssh_pub_key_path = "~/.ssh/id_ed25519.pub"

proxmox_endpoint = "https://192.168.1.10:8006"
proxmox_token    = "terraform-prov@pve!terraform=<uuid>"   # pve-token.txt'ten
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
    ip_start_index    = 174      # son oktet: master .174
    #template_vm_id = 9010 common dakini değiştirmek isterseniz.
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
    ip_start_index    = 184      # worker .184, .185
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

**Ne yapacak:** `deploy.sh` her koşuda `common.tfvars` + ilgili stack tfvars dosyasını birlikte verir; ikisi de diskte yoksa koşu başlamaz.

**Detay:** [docs/tr/proxmox/proxmox-preps.md](proxmox/proxmox-preps.md)

## Adım 7 — State encryption key

**Komut:**

```bash
./scripts/tofu-keys/init-encryption.sh
cp tofu/secrets/encryption.key backups/encryption.key
```

**Ne yapacak:** `tofu/secrets/encryption.key` dosyasını üretir (rasgele 32 bayt, `chmod 600`) ve ekrana yedekleme talimatı basar — anahtarı otomatik kopyalamaz; `backups/` altındaki yedek kopya yukarıdaki `cp` komutuyla alınır. `k8s-cluster`, `databases`, `efk` ve `openbao` stack'lerinin state'i PBKDF2 + AES-GCM ile bu anahtardan türetilen anahtarla şifrelenir (floci ve laws hariç — emülatör amaçlıdır). **Anahtar kaybedilirse state'ler geri okunamaz**; bu nedenle yedek kopya zorunludur. `--force` eski state'leri okunamaz bırakır.

**Doğrulama:** `ls -l tofu/secrets/encryption.key backups/encryption.key`

## Adım 8 — Garage state deposu (CT 300)

**Ne lazım:** Adım 1 (SSH), Adım 7 (encryption key).

**Komut:**

```bash
cd scripts/garage-setup
cp garage-setup.env.example .garage-setup.env
# .garage-setup.env içinde GARAGE_PVE_IP=<PVE_IP> düzenlenir
./chef.sh --tofu-backend true
cd ../..
```

**Ne yapacak:** Garage LXC'yi **tofu'nun dışında** kurar (state altyapısı tofu init'ten önce hazır olmalıdır): Alpine LXC açar, `opentofu-state` kovası + S3 anahtarını üretir, credential'ı `garage-300-credentials.txt` olarak çeker, **her stack için ayrı `tofu/backends/<stack>.backend.tfbackend` dosyasını otomatik yazar** (her stack'in state'i Garage'da kendi ayrı objesinde tutulur; bu dosyalar tofu init'in doğrudan girdisidir) ve CT'yi silmeye karşı korur. LXC IP'si (ör. `.100`) interaktif seçimle belirlenir; kurulum sonrası talimatlar ekrana basılır.

**Doğrulama:** `curl http://<garage-ip>:3900/` bir HTTP yanıtı döner; `ls tofu/backends/` içinde 6 `.backend.tfbackend` dosyası vardır.

**Detay:** [docs/tr/garagehq/chef-sh-how-it-works.md](garagehq/chef-sh-how-it-works.md)

## Adım 9 — OpenBao LXC (tofu)

**Komut:**

```bash
cd tofu
./deploy.sh dev openbao
cd ..
```

**Ne yapacak:** OpenBao LXC'yi (CT 301, Ubuntu 26.04) açar ve `ansible/inventory/openbao.ini.generated` envanterini üretir. `deploy.sh` = `tofu init -backend-config=backends/openbao.backend.tfbackend` + `tofu apply` (onay interaktif sorulur).

**Doğrulama:** `ssh root@<PVE_IP> "pct list"` içinde CT 301 görünür; `ls ansible/inventory/openbao.ini.generated`.

**Detay:** [platform-handbook.md](platform-handbook.md) §3.5, §3.7

## Adım 10 — OpenBao kurulumu (Ansible)

**Komut:**

```bash
cd ansible
ansible-playbook -i inventory/openbao.ini.generated playbooks/openbao.yml
cd ..
```

**Ne yapacak:** OpenBao 2.6.2'yi kurar; **init (Shamir 3/5) + unseal + PKI Root/Intermediate CA + tüm policy/rol/mount'lar otomatik yapılır** — elle unseal veya PKI adımı yoktur. Init sırasında unseal key'leri ve root token **otomatik olarak** şu dosyalara yazılır (0600):

- `ansible/outputs/openbao/openbao-unseal-keys.txt` — insan-okur özet (threshold, host, root token, unseal key listesi)
- `ansible/outputs/openbao/openbao-credentials.yml` — yeniden koşularda okunan YAML kopya
- `scripts/openbao-unseal/credentials.txt` — `unseal.sh`'in otomatik okuduğu dosya; her init'te güncellenir

Ayrıca `ansible/outputs/openbao/openbao-config.json` (K8s playbook'u bunu arar) ve `ops-admin.json` gibi platform token dosyaları üretilir.

**Elle yapılacak:** Bu dosyalardaki unseal key'leri ve root token **parola kasasına** kopyalanır. PVE/LXC reboot sonrası OpenBao sealed açılırsa: `./scripts/openbao-unseal/unseal.sh` (credentials.txt'yi kendisi okur).

**Doğrulama:** `curl -sk https://<openbao-ip>:8200/v1/sys/health | jq` → `"initialized": true, "sealed": false`

**Detay:** [docs/tr/openbao/openbao-architecture-guide.md](openbao/openbao-architecture-guide.md)

## Adım 11 — Kubernetes VM'leri (tofu)

**Komut:**

```bash
cd tofu
./deploy.sh dev k8s-cluster
cd ..
```

**Ne yapacak:** 1 master + 2 worker VM açar (Adım 4 template'inden clone) ve `ansible/inventory/hosts.ini.generated` envanterini üretir. VM'ler cloud-init ilk açılışı tamamlanana dek SSH'a hazır olmayabilir (Ansible'ın ön kontrolü 120 sn'ye kadar bekler).

**Doğrulama:** `tofu output` (tofu/stacks/k8s-cluster içinde) IP listesini basar.

## Adım 12 — Kubernetes kurulumu (Ansible)

**Komut:**

```bash
cd ansible
ansible-playbook -i inventory/hosts.ini.generated playbooks/k8s.yml
cd ..
```

**Ne yapacak:** kubeadm kümesini kurar: Cilium CNI + LoadBalancer/Gateway API + metrics-server + cert-manager + Secrets Store CSI + **OpenBao entegrasyonu (openbao-ops rolü)** + Cilium ağ politikaları + 5 insan kubeconfig'i. **Adım 10 zorunludur** — ön kontrol `outputs/openbao/openbao-config.json` yoksa playbook başında durur. Çıktılar: `ansible/outputs/k8s/` altında `admin/developer/deployer/monitoring/viewer` kubeconfig'leri.

**Doğrulama:** `kubectl --kubeconfig ansible/outputs/k8s/admin.conf get nodes` → 3 node `Ready`.

**Detay:** [platform-handbook.md](platform-handbook.md) §3.8

---

# Opsiyonel Parçalar

## Adım 13 — Kubernetes uygulamaları

**Komut:**

```bash
cd ansible
ansible-playbook -i inventory/hosts.ini.generated playbooks/k8s_apps.yml
cd ..
```

**Ne yapacak:** `charted.prom_stack` (kube-prometheus-stack: Prometheus + Grafana + Alertmanager) ve `apps[]` içinde `enable: true` olan uygulamaları kurar. Tek uygulama/chart: `-e app_filter=<ad>` / `-e chart_filter=<ad>`. Semantik: **apply yalnız `enable`'a bakar**; `state: absent` yalnız remove playbook'unda anlamlıdır. Grafana yönetici parolası (`group_vars/all/k8s_apps.yml` içindeki örnek değer) kurulum öncesinde değiştirilir.

**Detay:** [docs/tr/architecture/k8s-apps-design.md](architecture/k8s-apps-design.md)

## Adım 14 — Emülatörler: Floci (VM) + Laws (LXC)

**Komut:**

```bash
# Floci
cd tofu && ./deploy.sh dev floci && cd ..
cd ansible && ansible-playbook -i inventory/floci.ini.generated playbooks/floci.yml && cd ..

# Laws
cd tofu && ./deploy.sh dev laws && cd ..
cd ansible && ansible-playbook -i inventory/laws.ini.generated playbooks/laws.yml && cd ..
```

**Ne yapacak:** Floci: VM + Docker + LocalStack uyumlu AWS emülatörü (port 4566). Laws: LXC + tek Rust binary + systemd (port 4566). Floci stack'inin `ssh_user` varsayılanı ortama özeldir — kurulum öncesinde `tofu/stacks/floci/common.tofu` içinde kendi kullanıcı adınıza göre değiştirilir. floci/laws state'leri şifrelenmez (emülatör amaçlıdır).

**Doğrulama:** `curl http://<floci-ip>:4566/_localstack/health` ve `curl http://<laws-ip>:4566/health`.

**Detay:** [docs/tr/emulators/laws-test-commands.md](emulators/laws-test-commands.md)

## Adım 15 — Databases + EFK (WIP)

**Komut:**

```bash
cd tofu && ./deploy.sh dev databases && cd ..
cd tofu && ./deploy.sh dev efk && cd ..
```

**Ne yapacak:** Yalnızca VM'leri açar (db-primary: +50 GB data diski; elasticsearch: 8 GB RAM + 50 GB data diski). Bu iki stack **WIP** durumundadır: Ansible rolleri henüz yoktur; VM'ler K8s kümesine katılmaz ve sıralamadan bağımsız herhangi bir noktada çalıştırılabilir.

## Adım 16 — Yedekleme altyapısı (Garage2 + maintenance)

**Ne lazım:** Adım 9–11 tamamlanmış olmalı — bakım envanteri tofu'nun ürettiği `hosts.ini.generated` + `openbao.ini.generated` dosyalarından türetilir.

**Komut:**

```bash
cd scripts/garage-setup
./chef.sh --tofu-backend false --enable-ssh true --ctid 320 --disk 8
cd ../..

cd ansible
ansible-playbook -i inventory/maintenance-320.ini.generated playbooks/maintenance.yml
cd ..
```

**Ne yapacak:** İkinci Garage'ı (CT 320) yedek deposu olarak açar: `opentofu-state` kovalarını atar, node_exporter + python3 kurar, **restic parolalarını üretir** (`ansible/outputs/garage-backups/ct-320/restic-*.pw`) ve bakım envanterini (`maintenance-320.ini.generated`) yazar. `maintenance.yml`: 6 restic yedekleme job'ı + systemd timer'ları + node_exporter metrikleri + alertler. Restic parolası kaybedilirse kovadaki yedeklerin tamamı kaybolur — parolalar asla yeniden üretilmez, parola kasasına kopyalanır.

**Doğrulama:** `maintenance.yml` koşusu `failed=0` ile biter.

**Detay:** [docs/tr/maintenance/maintenance.md](maintenance/maintenance.md) §4.4

---

# Ekler

## A. Ortama Uyarlama Tablosu

| Değer | Nerede | Ne yazılır |
|---|---|---|
| `<PVE_IP>` | tüm komutlar | PVE makinesinin adresi |
| `target_node` | `tofu/environments/dev/common.tfvars` | PVE hostname'i (Adım 2 keşif çıktısı) |
| `template_vm_id` | `common.tfvars` | Adım 4 çıktısındaki VM ID |
| `base_ip` / `ip_mask` / `gateway` | `common.tfvars` + `openbao.tfvars` | Kendi ağınız (Adım 2 keşif çıktısı) |
| `ip_start_index` / `ip_offset` | stack tfvars'ları | Kendi IP planınız (boş son-oktet aralıkları) |
| `ct_id` (301, 302, 320) / `GARAGE_CT_ID` (300, 320) | `laws.tfvars`, `.garage-setup.env`, `--ctid` | Çakışmayan boş CT ID'leri |
| `disk_storage` / `data_disk_storage` | stack tfvars'ları | PVE storage adı (`pvesm status`; varsayılan `local-lvm`) |
| `LXC template_file_id` | `openbao.tfvars`, `laws.tfvars` | `pveam list local` çıktısındaki gerçek şablon adı |
| `ssh_user` (Floci) | `tofu/stacks/floci/common.tofu` | Kendi kullanıcı adınız |
| `root_password` (OpenBao) | `openbao.tfvars` içine `root_password = "..."` eklenerek | Stack varsayılanı örnek değerdir; kendi güçlü parolanız yazılır |
| `openbao.pki.domain` (base_domain) | `ansible/inventory/group_vars/all/all.yml` | Varsayılan iç domain; istenirse kendi domain'iniz |
| `k8s_cluster.lb_ip_pool` | `all.yml` | Subnet'inizde kullanılmayan IP aralığı (Gateway LoadBalancer havuzu) |
| `openbao.rbac.ops_admin_cidrs` | `all.yml` | Ops-admin token'ının bağlanabileceği CIDR'ler (boş = sınırsız; daraltılması önerilir) |
| `maintenance.homelab_cidr` | `group_vars/all/maintenance.yml` | `base_ip`/`ip_mask` ile aynı ağ |
| Grafana `admin_password` | `group_vars/all/k8s_apps.yml` | Örnek değer değiştirilir |

Ağ bridge'i `vmbr0` tofu modüllerinde sabittir; farklı bridge kullanımı `tofu/modules/proxmox-vm/main.tf` ve `tofu/modules/proxmox-lxc/main.tf` güncellenmesini gerektirir.

## B. Kritik Uyarılar

1. **Git'e girmeyen dosyalar** (klonla gelmez, kurulum sırasında üretilir — `.gitignore` kapsamındadır): `tofu/environments/**/*.tfvars`, `tofu/secrets/encryption.key`, `tofu/backends/*.tfbackend`, `scripts/proxmox/pve-token.txt`, `scripts/garage-setup/.garage-setup.env`, `scripts/garage-setup/garage-*-credentials.txt`, `scripts/openbao-unseal/credentials.txt`, `ansible/outputs/**`, `ansible/inventory/*.ini.generated`. Bu dosyaların parola kasası/yerel yedek dışında üçüncü bir kopyası tutulmaz.
2. **encryption.key** kaybedilirse state'ler geri okunamaz → `backups/encryption.key` kopyası zorunludur (Adım 7).
3. **State yerleşimi:** Her stack, Garage'da kendi ayrı state objesini kullanır (`tofu/backends/<stack>.backend.tfbackend` → `<stack>/terraform.tfstate`); stack'ler birbirinin state'ine dokunmaz.
4. **S3 backend kilitleme içermez** — aynı stack'e paralel `tofu apply` yapılmaz.
5. **Restic parolaları** asla üzerine yazılmaz / yeniden üretilmez; kayıp parola = o kovadaki yedeklerin tamamının kaybı.
6. **PVE reboot sonrası** OpenBao sealed açılır → `./scripts/openbao-unseal/unseal.sh`.

## C. Hızlı Sağlık Kontrolleri

| Hedef | Komut | Beklenen |
|---|---|---|
| Garage S3 | `curl http://<garage-ip>:3900/` | HTTP yanıtı |
| OpenBao | `curl -sk https://<openbao-ip>:8200/v1/sys/health` | `initialized: true, sealed: false` |
| Kubernetes | `kubectl --kubeconfig ansible/outputs/k8s/admin.conf get nodes` | 3 node `Ready` |
| Floci | `curl http://<floci-ip>:4566/_localstack/health` | Servis listesi |
| Laws | `curl http://<laws-ip>:4566/health` | Sağlık yanıtı |

Uygulama host adları (ör. `echo.<base_domain>`) Gateway'in LoadBalancer IP'sine (`lb_ip_pool` havuzundan) `/etc/hosts` ile çözülür.

## D. Kurulum Sonrası Okuma Listesi

| Belge | İçerik |
|---|---|
| [platform-handbook.md](platform-handbook.md) | Platform el kitabı: mimari, deploy sırası (§3.2), bileşenler |
| [docs/tr/architecture/master-design.md](architecture/master-design.md) | Genel mimari |
| [docs/tr/openbao/openbao-architecture-guide.md](openbao/openbao-architecture-guide.md) | OpenBao mimarisi ve işletimi |
| [docs/tr/openbao/openbao-rbac.md](openbao/openbao-rbac.md) | W/P/S kimlik kataloğu, politika demetleri |
| [docs/tr/garagehq/chef-sh-how-it-works.md](garagehq/chef-sh-how-it-works.md) | Garage kurulum orkestratörünün tam anlatımı |
| [docs/tr/maintenance/maintenance.md](maintenance/maintenance.md) | Yedekleme/geri yükleme mimarisi |
| [docs/tr/maintenance/disaster-recovery.md](maintenance/disaster-recovery.md) | Senaryo bazlı kurtarma |
| [docs/tr/cloud-equivalents.md](cloud-equivalents.md) | Bulut karşılıkları karşılaştırması |
