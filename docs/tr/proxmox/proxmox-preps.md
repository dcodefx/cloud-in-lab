# Proxmox VE 9 — Hazırlık

Proxmox tarafında OpenTofu için üç şey hazırlanmalıdır:

1. **API token** — Tofu'nun Proxmox'a bağlanması için
2. **VM template** — Cloud-image'den VM klonlamak için
3. **Network keşif** — Proxmox ağ bilgilerini öğrenmek için (gateway, bridge, DNS vb.)

Tüm hazırlık script'leri `scripts/proxmox/` altındadır ve SSH'ı kendi içinde yapar. 

> **Not:** Aşağıdaki tüm IP adresleri, çıktı örnekleri ve VM ID'leri **örnek amaçlıdır**; kendi ortamınızdaki değerlerle değiştirin.

```bash
./scripts/proxmox/discover-pve.sh 164.102.98.152         # → pve-discovered.txt
./scripts/proxmox/setup-proxmox-token.sh --host 164.102.98.152  # → pve-token.txt
./scripts/proxmox/create-vm-template.sh --host 164.102.98.152  # → Proxmox'ta template oluşturur
```

---

## Script'ler

| Script | Ne Yapar | Çıktı |
|--------|----------|-------|
| `discover-pve.sh <IP>` | Proxmox ağ bilgilerini toplar | `pve-discovered.txt` (yerel) |
| `setup-proxmox-token.sh --host <IP>` | Role + kullanıcı + token oluşturur | `pve-token.txt` (yerel) + `/root/pve-credentials.txt` (yedek, opsiyonel) |
| `create-vm-template.sh --host <IP> [--distro …] [--version …]` | Cloud-image'den VM template oluşturur | Proxmox'ta template |

---

## 1. Network Keşif

Proxmox'un ağ bilgilerini (gateway, bridge, DNS, storage, mevcut VM'ler) öğrenmek için:

```bash
./scripts/proxmox/discover-pve.sh 164.102.98.152
```

Çıktı (`pve-discovered.txt`):

```
target_node = "pve"
gateway = "164.102.98.70"
bridge = "vmbr0"
pve_ip = "164.102.98.152"
subnet_mask = "24"
proxmox_endpoint = "https://164.102.98.152:8006"
dns = "8.8.8.8"

##### STORAGE LISTESI #####
local-lvm | lvmthin | rootdir,images

##### VM TEMPLATELERI #####
# vmid | name | status
9000 | base-vm | template

##### MEVCUT VM/LXC LISTESI #####
101 | k8s-master | qemu | running | -
102 | k8s-worker | qemu | running | -

##### ALPINE CT TEMPLATE #####
alpine-3.23-default_20260116_amd64.tar.xz
```

Bu bilgiler `common.tfvars`'a elle aktarılır.

**Çıktı → Kullanım:**

| pve-discovered.txt | common.tfvars |
|-------------------|---------------|
| `target_node = "pve"` | `target_node = "pve"` |
| `gateway = "164.102.98.70"` | `gateway = "164.102.98.70"` |
| `pve_ip = "164.102.98.152"` | `proxmox_endpoint = "https://164.102.98.152:8006"` |
| `subnet_mask = "24"` | `ip_mask = "24"` |
| `proxmox_endpoint = "https://..."` | aynen yaz |
| `dns = "8.8.8.8"` | DNS için ayrı alan yok, Tofu'da opsiyonel |
| Storage listesi | `common.tfvars`'da disk/storage tanımı için referans |
| VM template listesi | `template_vm_id` için hangi ID'nin kullanılacağını gösterir |

---

## 2. API Token

### Script ile

```bash
./scripts/proxmox/setup-proxmox-token.sh --host 164.102.98.152
# İsteğe bağlı parametreler
./scripts/proxmox/setup-proxmox-token.sh --host 164.102.98.152 --user terraform-prov --realm pve --force
```

Tüm seçenekleri görmek için:

```bash
./scripts/proxmox/setup-proxmox-token.sh --help
```

| Flag | Açıklama | Varsayılan |
|------|----------|------------|
| `--host <ip>` | **(zorunlu)** Proxmox host adresi | — |
| `--user <ad>` | API token kullanıcısı | `terraform-prov` |
| `--realm <pve\|pam>` | Kullanıcı realm'ı (otomasyon için `pve` önerilir) | `pve` |
| `--token-id <ad>` | Token ID | `terraform` |
| `--role <ad>` | Rol adı | `TerraformProv` |
| `--privs "<liste>"` | Özel yetki listesi | PVE9 varsayılan yetkiler |
| `--acl-path <path>` | ACL kapsamı | `/` (tüm cluster) |
| `--output <dosya>` | Yerel çıktı dosyası | `./pve-token.txt` |
| `--force` | Var olan role/user/token'ı silip yeniden oluşturur (eski token geçersizleşir) | kapalı |
| `--skip-backup` | Host üzerinde `/root/pve-credentials.txt` yedeğini oluşturma | kapalı (yedek alınır) |
| `-h`, `--help` | Bu yardımı göster | — |

Script şunları yapar:

1. `TerraformProv` rolünü PVE9 güncel yetki listesiyle oluşturur / günceller; `--force` ile yeniden oluşturur
2. Kullanıcıyı varsayılan `terraform-prov@pve` olarak oluşturur / atlar; realm `pve` varsayılan, `@pam` seçilirse uyarı verir
3. ACL'yi `/` altında kullanıcıya atar
4. Token `terraform-prov@pve!terraform` oluşturur / idempotent; `--force` ile eski tokenı siler ve yenisi oluşturur, eski token geçersizleşir
5. Yerel `pve-token.txt` dosyasını `chmod 600` ile yazar
6. Host üzerinde `/root/pve-credentials.txt` yedeğini opsiyonel oluşturur, `--skip-backup` ile kapatılabilir

Token satırını `common.tfvars`'a eklemek için:

```bash
cat pve-token.txt
# proxmox_token = "terraform-prov@pve!terraform=aa21c577-..."
```

**Çıktı → Kullanım:**

| pve-token.txt | common.tfvars |
|--------------|---------------|
| `proxmox_token = "terraform-prov@pve!terraform=..."` | `proxmox_token = "terraform-prov@pve!terraform=..."` |

kopyalanıp ilgili yere yapıştırılır.

### Manuel

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

> Not: Otomasyon için realm `pve` tercih edilir. `@pam` kullanılırsa host üzerinde aynı isimde Linux kullanıcısının bulunması gerekir.

### Yetki Tablosu

| Privilege | Neden Gerekli |
|-----------|---------------|
| `VM.Allocate` | VM oluşturma/silme |
| `VM.Clone` | Template'den clone |
| `VM.Config.CPU` | CPU ayarları |
| `VM.Config.Memory` | RAM ayarları |
| `VM.Config.Disk` | Disk ekleme/çıkarma |
| `VM.Config.Network` | Network arayüzü |
| `VM.Config.Cloudinit` | Cloud-init (IP, SSH key) |
| `VM.Config.Options` | VM özellikleri |
| `VM.Config.CDROM` | CD-ROM yönetimi |
| `VM.Config.HWType` | Donanım tipi |
| `VM.Audit` | VM konfigürasyonu okuma |
| `VM.PowerMgmt` | VM başlatma/durdurma |
| `VM.Migrate` | VM taşıma |
| `VM.GuestAgent.Audit` | Guest agent sorgulama |
| `Datastore.AllocateSpace` | Disk alanı ayırma |
| `Datastore.AllocateTemplate` | Template indirme/oluşturma |
| `Datastore.Audit` | Storage görüntüleme |
| `Pool.Allocate` | Pool'a VM ekleme |
| `Pool.Audit` | Pool bilgisi okuma |
| `Sys.Audit` | Node durumu okuma |
| `Sys.Console` | Konsol erişimi |
| `Sys.Modify` | Sistem ayarları |
| `SDN.Use` | SDN kullanımı |
---

**Token yenileme:**

```bash
pveum user token remove terraform-prov@pve terraform
pveum user token add terraform-prov@pve terraform --output-format json
./scripts/proxmox/setup-proxmox-token.sh --host 164.102.98.152 --force
```

> `--force` eski tokenı siler ve yenisi oluşturur; eski tokenı kullanan tüm sistemler güncellenmelidir.

---

## 3. VM Template

> Detaylı kullanım, tüm parametreler ve örnekler için bkz. `docs/tr/proxmox/how-to-create-vm-template.md`. Aşağıda özet kullanım yer almaktadır.

### Script ile

```bash
# Ubuntu 26.04, VM ID otomatik, storage local-lvm (varsayılan)
./scripts/proxmox/create-vm-template.sh --host 164.102.98.152 --distro ubuntu --version 26.04

# Debian 13, VM ID 9001, storage local-lvm
./scripts/proxmox/create-vm-template.sh --host 164.102.98.152 --distro debian --version 13 --vmid 9001 --storage local-lvm
```

Script, gömülü dağıtım/versiyon eşlemeleriyle çalışır ve aynı zamanda `--image-url --os-family` ile listede olmayan her cloud image’ı da kullanabilir.
Bu sayede dağıtım listesi sabit değildir.

Parametrelerle `CPU/RAM/disk` boyutu, `BIOS/UEFI, bridge/VLAN, cloud-init kullanıcı/SSH key/DNS, qemu-guest-agent kurulum yöntemi, checksum doğrulama, dry-run, force` vb. tamamen özelleştirilebilir. **Detaylı parametre seti ve örnekler** için `docs/tr/proxmox/how-to-create-vm-template.md`.

Gömülü destek: `ubuntu` 20.04/22.04/24.04/24.10/25.04/25.10/26.04, `debian` 11/12/13, `rocky` 8/9, `almalinux` 8/9. Mevcut liste ve varsayılanlar için `--list-distros` veya `docs/tr/proxmox/how-to-create-vm-template.md`.

**Çıktı → Kullanım:**

| Script çıktısı | common.tfvars |
|----------------|---------------|
| `template_vm_id = 9000` | `template_vm_id = 9000` |

Storage adını (`local-zfs`, `local-lvm` vb.) not et, `common.tfvars`'da VM disk tanımında kullanılacak.

---

## 4. common.tfvars - Değer Haritası

Keşif ve token script'lerinden alınan değerler, `tofu/environments/dev/common.tfvars` içine yazılır:

| Değer | Kaynak | common.tfvars Alanı |
|-------|--------|-------------------|
| PVE IP + port | `discover-pve.sh` (pve_ip) | `proxmox_endpoint = "https://164.102.98.152:8006"` |
| API token | `setup-proxmox-token.sh` | `proxmox_token = "terraform-prov@pve!terraform=..."` |
| PVE node adı | `discover-pve.sh` (target_node) | `target_node = "pve"` |
| Template VM ID | `create-vm-template.sh` | `template_vm_id = 9000` |
| Ağ adresi | `discover-pve.sh` çıktısından **türetilir** (script `base_ip` yazmaz; `pve_ip`/gateway'a bakıp ağın `.0` adresini elle yaz; ör. `164.102.98.16` → `164.102.98.0`) | `base_ip = "164.102.98.0"` |
| Alt ağ maskesi | `discover-pve.sh` (subnet_mask) | `ip_mask = "24"` |
| Ağ geçidi | `discover-pve.sh` (gateway) | `gateway = "164.102.98.70"` |
| SSH public key | Kendi SSH key'in | `ssh_pub_key_path = "~/.ssh/id_ed25519.pub"` |

---

## 5. Sık Yapılan Hatalar

| Hata | Sebep | Çözüm |
|------|-------|-------|
| `permission denied` | Token yetkisi yetersiz | Role'de tüm VM.* privilege'ları var mı kontrol et |
| `Permission check failed` / Datastore.AllocateTemplate | Token'ın storage'a template indirme yetkisi yok | Role'e `Datastore.AllocateTemplate` ekle (yukarıdaki nota bak) |
| `no template found` | Template VM ID yanlış | `pvesh get /cluster/resources --type vm` ile ID'yi doğrula |
| `disk image too large` | Storage alanı yetmez | `pvesh get /storage/<STORAGE>/status` ile alan kontrolü |
| `address already in use` | IP çakışması | `base_ip` + `ip_start_index` kontrol et |
| `could not parse token` | Token formatı yanlış | `KULLANICI@REALM!TOKEN_ID=SECRET` formatını kullan |
| SSH bağlantı reddi | Proxmox'a erişim yok | `ssh root@<IP` ile bağlantıyı test et |


---