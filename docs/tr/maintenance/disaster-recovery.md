# Disaster Recovery — Senaryo ve Çözümler

Bu dosyada olası felaket senaryolarına karşı alınabilecek önlemler
senaryo ve çözümleri şeklinde anlatılmıştır. Yedekleme mimarisi, restic kova
yapısı, saklama limitleri ve izleme zinciri
[`maintenance.md`](maintenance.md) dosyasında; `restore.sh` akışı, güvenlik
adımları ve rollback prosedürleri ise
[`restore-sh-how-it-works.md`](restore-sh-how-it-works.md) dosyasında yer alır.

---

## Kriz Anı Erişim Bilgileri

Kriz anında aşağıdaki bilgilere hızlıca erişilebilir olmalıdır:

| Bilgi | Konum |
|-------|-------|
| `encryption.key` | `tofu/secrets/encryption.key` (orijinal) + `backups/encryption.key` (kopya) |
| Restic parolaları | `/etc/tofu-lar/backup/*.pw` (her job için ayrı) |
| Unseal key'ler | Password manager (hiçbir yedek kanalında tutulmaz) |
| Garage2 S3 endpoint | `http://<garage2-ip>:3900` |
| VMID'ler | Proxmox host'ta `pct list` / `qm list` |

### VMID Sembolleri

Aşağıdaki komutlarda geçen VMID değerleri her kurulumda farklıdır:

| Sembol | Karşılığı | Nasıl öğrenilir |
|--------|-----------|-----------------|
| `<GARAGE_VMID>` | Garage LXC'nin Proxmox VMID'si | Proxmox host'ta `pct list` |
| `<OPENBAO_VMID>` | OpenBao LXC'nin Proxmox VMID'si | Proxmox host'ta `pct list` |
| `<K8S_MASTER_VMID>` | K8s master VM'nin Proxmox VMID'si | Proxmox host'ta `qm list` |

### Çalışma Yerleri

| Komut | Çalışma yeri | Yetki |
|-------|--------------|-------|
| `restore-vm.sh` | Proxmox host | root |
| `restore-etcd.sh` | K8s master VM | root |
| `restore-openbao.sh` | OpenBao LXC | root |
| `unseal.sh` | Kontrol makinesi | — |

---

## Senaryo Bazlı Kurtarma Planı

### Senaryo A: Kubernetes etcd Veri Bozulması

**Tetikleyici:** Cluster API yanıt vermiyor, etcd verisi bozuk.

**Kurtarma Adımları:**

```bash
# K8s master VM'de, root yetkisiyle
./restore/restore-etcd.sh --tier daily --yes
```

**Doğrulama:**

```bash
kubectl get nodes
kubectl get pods --all-namespaces
```

**Not:** Snapshot anından sonraki tüm değişiklikler kaybolur. Kontrol düzlemi
static pod'lardır; `systemctl stop etcd` çalışmaz.

### Senaryo B: Kubernetes Master Node Çökmesi

**Tetikleyici:** K8s master VM erişilemez.

**Kurtarma Adımları:**

```bash
# Proxmox host'ta
./restore/restore-vm.sh --vmid <K8S_MASTER_VMID> --yes
```

**Doğrulama:**

```bash
kubectl get nodes
```

**Not:** etcd verisi bozuk değilse, master VM restore edilir ve cluster
toparlanır. etcd restore gerekmez.

### Senaryo C: OpenBao Raft Veri Kaybı

**Tetikleyici:** OpenBao veri katmanı bozuldu, secret ve PKI okunamıyor.

**Kurtarma Adımları:**

```bash
# 1. LXC ayakta değilse önce restore et
./restore/restore-vm.sh --vmid <OPENBAO_VMID> --yes

# 2. Unseal et (3/5 eşik)
./scripts/openbao-unseal/unseal.sh

# 3. Raft snapshot geri yükle (OpenBao LXC'de, root yetkisiyle)
./restore/restore-openbao.sh --tier daily --yes
```

**Doğrulama:**

```bash
bao status
bao secrets list
```

**Not:** Geri yükleme OpenBao verisini snapshot anına döndürür. Unseal adımı
zorunludur; sealed durumda API kullanılamaz.

### Senaryo D: Proxmox Host / Sanal Makine Tam Kaybı

**Tetikleyici:** Proxmox host veya sanal makine tamamen kayboldu.

**Kurtarma Adımları:**

```bash
# Proxmox host'ta
./restore/restore-vm.sh --vmid <VMID> --yes
```

**Doğrulama:**

```bash
pct status <VMID>  # veya qm status <VMID>
```

**Not:** `restore-vm.sh` hedef VMID'de kayıtlı bir LXC veya VM varsa onu
durdurup `pct destroy`/`qm destroy --purge` ile kalıcı olarak siler, ardından
aynı VMID'ye geri yükler. Geri yükleme başarısız olursa eski guest de yeni
kopya da ortada kalmaz.

### Senaryo E: Tüm Proxmox Host Gitti

**Tetikleyici:** Tüm Proxmox host kayboldu.

**Kurtarma Adımları:**

```bash
# 1. Garage LXC
./restore/restore-vm.sh --vmid <GARAGE_VMID> --yes

# 2. OpenBao LXC
./restore/restore-vm.sh --vmid <OPENBAO_VMID> --yes

# 3. Unseal
./scripts/openbao-unseal/unseal.sh

# 4. K8s master VM
./restore/restore-vm.sh --vmid <K8S_MASTER_VMID> --yes

# 5. etcd (K8s master'da)
./restore/restore-etcd.sh --tier daily --yes

# 6. Worker node'lar → Tofu ve Ansible ile yeniden kur
```

**Doğrulama:**

```bash
kubectl get nodes
bao status
```

**Not:** `restore.sh all` komutu VM/LXC ve etcd kurtarmasını tek adımda yapar,
ancak raft kurtarması içermez. Raft geri yüklemesi OpenBao LXC'sinde, unseal
sonrasında çalışabildiği için ayrı bir adımdır.

### Senaryo F: Backup Durdu

**Tetikleyici:** Yedekler bayatladı, yedekleme durdu.

**Kurtarma Adımları:**

```bash
# Herhangi bir host'ta
./restore/restore.sh health
```

**Doğrulama:**

```bash
# Çıktıda [SORUN] yoksa yedekler sağlıklı
```

**Not:** `restore.sh health` her iş için son başarılı backup zamanını okur ve
beklenen aralık aşılmışsa `[SORUN]` basıp `exit 1` verir.

### Senaryo G: encryption.key Kayboldu

**Tetikleyici:** Tofu state'leri okunamıyor.

**Kurtarma Adımları:**

```bash
# Kontrol makinesinde
cat tofu/secrets/encryption.key
# veya
cat backups/encryption.key
```

**Doğrulama:**

```bash
tofu plan
```

**Not:** Anahtar yalnızca kontrol makinesinde iki kopyada bulunur; offsite
kopyası yoktur. Kontrol makinesinin diski kaybolursa Tofu state'leri
çözülemeyeceğinden, anahtarı başka bir ortama yedeklemek gerekir.

### Senaryo H: Unseal Key'ler Kayboldu

**Tetikleyici:** OpenBao açılamıyor.

**Kurtarma Adımları:**

```bash
# Password manager'dan unseal key'lerini al
# 3/5 eşik gereklidir
```

**Doğrulama:**

```bash
bao status
```

**Not:** Shamir key'leri hiçbir yedek kanalında tutulmaz; yalnızca password
manager'da bulunur.

---

## Komut ve Konfigürasyon Ayrımı

**Konfigürasyonlar** (retention sayıları, timer takvimleri, env değişkenleri):
`maintenance.md` ve `ansible/roles/maintenance/defaults/main.yml` içinde.

**Komutlar:** Bu dokümanda sırasıyla kopyala-yapıştır yapılabilir netlikte,
parametre açıklamalarıyla yer alır.

**Restore script'leri:** `maintenance/restore/` altındaki beş script elle
çağrılır; `tasks/restore.yml` boş bir yer tutucudur ve `maintenance.restore.enabled`
`false`'dır, yani playbook restore'u çalıştırmaz.
