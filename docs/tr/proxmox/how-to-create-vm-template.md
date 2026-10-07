# create-vm-template.sh — Kullanım Kılavuzu

Proxmox VE 8/9 üzerinde cloud-image tabanlı VM template'leri oluşturan, dinamik ve genişletilebilir bir script. OpenTofu/Terraform ile IaC akışında `template_vm_id` olarak kullanılacak temiz, cloud-init destekli template üretir.

---

## Gereksinimler

- **Çalışacak makinede :** `bash`, `ssh`, `base64` — kurulu olmalı.
- **Proxmox host:** `root` ile SSH erişimi (key-based önerilir, parola sorulmaması için), `wget`, standart Proxmox araçları (`qm`, `pvesh`, `pvesm`) — bunlar zaten her Proxmox kurulumunda var
- İnternet erişimi (Proxmox host'undan cloud image indirilecek)

```bash
chmod +x create-vm-template.sh
```

---

## Hızlı Başlangıç

> **Not:** Bu belgedeki tüm IP adresleri ve çıktı örnekleri **örnek amaçlıdır**; kendi Proxmox host adresinizle değiştirin.

```bash
./create-vm-template.sh --host 164.102.98.152 --distro ubuntu --version 24.04
```

Bu tek komut:
1. Ubuntu 24.04 (noble) cloud image'ini Proxmox host'una indirir
2. Checksum'ını doğrular
3. Boş bir VM ID bulur (otomatik)
4. VM oluşturur, diski import eder, cloud-init disk'i ekler
5. qemu-guest-agent'ı ilk boot'ta kurulacak şekilde ayarlar
6. VM'i template'e çevirir

Sonunda şu görülecektir:
```
vm_id   = 9002
vm_name = ubuntu-24.04-template
storage = local-lvm
```

Bu ID'yi OpenTofu/Terraform config'indeki `template_vm_id` değişkenine yazmanız yeterli olacaktır.

---

## Önce plan görmek istenirse: `--dry-run`

Hiçbir işlem yapmadan, script'in ne yapacağını gösterir — SSH bağlantısı bile açmaz:

```bash
./create-vm-template.sh --host 164.102.98.152 --distro rocky --version 9 --dry-run
```

```
=== Plan ===
  Host:        164.102.98.152
  Dagitim:     rocky (9)
  Image URL:   https://dl.rockylinux.org/pub/rocky/9/images/x86_64/Rocky-9-GenericCloud-Base.latest.x86_64.qcow2
  OS ailesi:   rhel
  VM ID:       <otomatik>
  VM adi:      rocky-9-template
  ...
```

Yanlış bir versiyon/dağıtım yazıldı veya bir hatalı girdi verildiyse burada anlaşılabilir, gerçek indirme/VM oluşturma başlamadan.

---

## Desteklenen dağıtımlar

```bash
./create-vm-template.sh --list-distros
```

| Dağıtım | `--distro` | Desteklenen `--version` | Varsayılan |
|---|---|---|---|
| Ubuntu | `ubuntu` | 20.04, 22.04, 24.04, 24.10, 25.04, 25.10, 26.04 | 24.04 |
| Debian | `debian` | 11, 12, 13 | 13 |
| Rocky Linux | `rocky` | 8, 9 | 9 |
| AlmaLinux | `almalinux` (ya da `alma`) | 8, 9 | 9 |

Bu dört dağıtım için URL'ler **versiyon numarasından otomatik türetilir** —  `--version` parametresi ile farklı versiyonlar verilebilir.

### Listede olmayan bir dağıtım (Fedora, openSUSE, Arch, özel imaj...)

`--image-url` + `--os-family` ile herhangi bir cloud image kullanılabilir:

```bash
./create-vm-template.sh --host 164.102.98.152 \
  --image-url https://download.fedoraproject.org/pub/fedora/linux/releases/42/Cloud/x86_64/images/Fedora-Cloud-Base-42-1.1.x86_64.qcow2 \
  --os-family rhel \
  --name fedora-42-template
```

`--os-family` şu değerleri alır: `debian` | `rhel` | `arch` | `suse` — qemu-guest-agent'ın hangi paket yöneticisiyle (apt/dnf/pacman/zypper) kurulacağını belirler.

---

## Örnekler

### 1. Varsayılan ayarlarla Ubuntu template
```bash
./create-vm-template.sh --host 164.102.98.152
```
(distro=ubuntu, version=24.04, storage=local-lvm, vmid=otomatik)

### 2. Belirli bir VM ID ve ZFS storage
```bash
./create-vm-template.sh --host 164.102.98.152 \
  --distro debian --version 13 \
  --vmid 9010 --storage local-zfs
```

### 3. Daha güçlü template (4 core, 4GB RAM, 20GB disk)
```bash
./create-vm-template.sh --host 164.102.98.152 \
  --distro rocky --version 9 \
  --cores 4 --memory 4096 --disk-size 20G
```

### 4. Cloud-init kullanıcı + SSH key + DNS önceden gömülü
```bash
./create-vm-template.sh --host 164.102.98.152 \
  --distro ubuntu --version 24.04 \
  --ciuser devops \
  --ssh-pubkey-file ~/.ssh/id_ed25519.pub \
  --nameserver 1.1.1.1 --searchdomain lab.local
```
Bu template'ten türeyen her VM, ilk boot'ta `devops` kullanıcısıyla ve  public key'inizle hazır gelir — Ansible ile direkt SSH atabilirsiniz.

### 5. VLAN'lı bridge
```bash
./create-vm-template.sh --host 164.102.98.152 \
  --distro debian --bridge vmbr0 --vlan 30
```

### 6. UEFI (OVMF) gerektiren bir imaj için
```bash
./create-vm-template.sh --host 164.102.98.152 \
  --distro rocky --version 9 --bios ovmf
```
(`--bios ovmf` verilince `--machine` otomatik `q35` olur, `efidisk0` otomatik eklenir — elle bir şey ayarlamaya gerek kalmaz.)

### 7. Var olan bir VM ID'nin üzerine yazmak
```bash
./create-vm-template.sh --host 164.102.98.152 \
  --vmid 9000 --distro ubuntu --force
```
`--force` verilmezse script, ID zaten doluysa **hata verip durur** — yanlışlıkla üzerine yazmayı engellemek için.

### 8. qemu-guest-agent'ı imaja gömerek (cloud-init'te başlangıçta yüklemesi yerine)
```bash
./create-vm-template.sh --host 164.102.98.152 \
  --distro debian --use-virt-customize
```
Varsayılan davranış (cloud-init ile first-boot'ta kurulum) host'a hiçbir paket kurdurmaz. `--use-virt-customize` verilirse, Proxmox host'una `libguestfs-tools` kurulur ve agent doğrudan imaj dosyasının içine gömülür — daha "temiz" bir imaj ister ama host'a ekstra bağımlılık bindirir. Çoğu durumda varsayılanı kullanmak yeterli.

---

## Tüm parametreler

| Parametre | Açıklama | Varsayılan |
|---|---|---|
| `--host <ip>` | **(zorunlu)** Proxmox host adresi | — |
| `--distro <ad>` | ubuntu / debian / rocky / almalinux | `ubuntu` |
| `--version <sürüm>` | Dağıtım versiyonu | dağıtıma göre |
| `--image-url <url>` | Özel/listede olmayan cloud image | — |
| `--os-family <aile>` | `--image-url` ile birlikte: debian/rhel/arch/suse | — |
| `--vmid <id>` | Sabit VM ID | otomatik (`pvesh nextid`) |
| `--name <ad>` | Template adı | `<distro>-<versiyon>-template` |
| `--storage <ad>` | Proxmox storage adı | `local-lvm` |
| `--bridge <ad>` | Network bridge | `vmbr0` |
| `--vlan <tag>` | VLAN tag | — |
| `--cores <n>` | CPU çekirdek sayısı | `2` |
| `--memory <MB>` | RAM (MB) | `2048` |
| `--disk-size <boyut>` | Diski bu boyuta büyüt (örn. `20G`) | image'in kendi boyutu |
| `--cpu-type <tip>` | QEMU CPU tipi | `host` |
| `--bios <seabios\|ovmf>` | BIOS tipi | `seabios` |
| `--ciuser <kullanıcı>` | Cloud-init varsayılan kullanıcı | image varsayılanı |
| `--ssh-pubkey-file <yol>` | Yerel makinedeki public key dosyası | — |
| `--nameserver <ip>` | DNS sunucusu | — |
| `--searchdomain <domain>` | DNS search domain | — |
| `--use-virt-customize` | Agent'ı imaja göm (host'a libguestfs kurar) | kapalı (cloud-init kullanılır) |
| `--force` | Var olan VM ID'yi sil ve yeniden oluştur | kapalı |
| `--keep-image` | İndirilen imajı silme | kapalı (siliniyor) |
| `--strict-checksum` | Checksum uyuşmazsa dur | kapalı (uyarıp devam eder) |
| `--dry-run` | Hiçbir işlem yapmadan planı göster | kapalı |
| `--list-distros` | Desteklenen dağıtım/versiyonları listele | — |
| `-h`, `--help` | Yardım metni | — |

---

## Nasıl çalışıyor (kısa mimari özeti)

1. **Yerel taraf** (`bash create-vm-template.sh ...`): Argümanları parse eder, dağıtım adı + versiyondan gerçek indirme URL'ini ve checksum URL'ini hesaplar (`resolve_distro()`), sonra tüm parametreleri tek bir SSH oturumunda Proxmox host'una gönderir.
2. **Uzak taraf** (Proxmox host üzerinde çalışan gömülü script): cloud image'i indirir, checksum doğrular, `qm create` ile boş VM oluşturur, `qm importdisk` ile diski aktarır, **hangi storage tipi olursa olsun** (`unused0` diskini `qm config` çıktısından okuyarak) doğru volid'i bulup `scsi0`'a bağlar, cloud-init disk'ini ekler, gerekiyorsa diski büyütür, ve en son `qm template` ile şablona çevirir.
3. Herhangi bir adımda hata olursa (`trap cleanup`), o ana kadar oluşturulmuş yarım VM otomatik silinir — elde "hayalet" bir VM ID kalmaz.

---

## Sorun Giderme

**"virt-customize bulunamadi" / paket kurulum hatası (`--use-virt-customize` ile)**
Proxmox host'unun internet erişimi ve `apt` repo'larının çalışır durumda olması gerekir. Alternatif: bu flag'i hiç kullanma, varsayılan cloud-init yöntemi zaten çalışır ve host'a paket kurdurmaz.

**"Snippets destekli storage bulunamadi" uyarısı**
Cloud-init ile otomatik qemu-guest-agent kurulumu için Proxmox'ta en az bir storage'ın "Snippets" içerik tipini desteklemesi gerekir. Web UI'de: *Datacenter → Storage → local → Edit → Content → "Snippets" kutucuğunu işaretle*. Bu ayarlanmadan da template oluşur, sadece agent otomatik kurulmaz (VM'e sonradan elle kurman gerekir).

**Checksum uyuşmuyor**
Nadiren mirror gecikmesi/senkronizasyon farkından olabilir. `--strict-checksum` vermediysen script uyarıp devam eder; emin olmak isterseniz indirmeyi tekrar deneyebilir ya da `--keep-image` ile dosyayı inceleyebilirsiniz.

**"VM zaten mevcut" hatası**
Ya farklı bir `--vmid` verilmeli, ya da bilerek üzerine yazılmak isteniyorsa `--force` eklenmeli.
---

**Genel şablon:** 

```bash
./create-vm-template.sh --host <IP> --distro debian --version 13 --use-virt-customize
```

**Örnek bir kaç hazır komut:**
```bash
./create-vm-template.sh --host 164.102.98.16 --distro ubuntu --version 26.04 --use-virt-customize --vmid 9000


./create-vm-template.sh --host 164.102.98.16 --distro debian --version 13 --use-virt-customize --vmid 9010


./create-vm-template.sh --host 164.102.98.16 --distro rocky --version 9 --use-virt-customize --vmid 9020


./create-vm-template.sh --host 164.102.98.16 --distro debian --version 13 --use-virt-customize --vmid 9040 --cpu-type x86-64-v2-AES 
```


---