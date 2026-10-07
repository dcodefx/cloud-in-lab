# Proje Kısıtları ve Çözümleri

Bu dosya, projenin **bilinen sınırlarını** ve bu sınırların **homelab / simülasyon**
ölçeğinde nasıl idare edildiğini listeler.

**İlke:** Vaat edilen yapının büyük bölümü kuruludur (PKI, AppRole, backup, Cilium,
gateway TLS…). Buradaki maddeler bilinçli olarak ölçeklenmemiş alanlardır:
production-grade orkestrasyon, tam CRL altyapısı, multi-node HA vb. **Aşırı
mühendislik** sayılır; karşılığı çoğu zaman **basit prosedür, mevcut script veya
kısa TTL** ile kapanır.

Bu dosya **yapılacaklar backlog’u** veya **durum raporu** değildir. Efor iş kalemi
tutmaz; belirtilen sınır mevcut haliyle bu şekilde idare edilir.

İlgili: `master-design.md` (yedekleme akışı, Cilium §8.4),
`docs/tr/maintenance/maintenance.md` (yedekleme mimarisi),
`docs/tr/openbao/openbao-architecture-guide.md` §11.2,
`docs/tr/maintenance/disaster-recovery.md`,
`docs/tr/openbao/openbao-rbac.md` §11.

---

## Özet liste

| # | Kısıt | Yaklaşım | Pratik karşılık | Gerekçe |
|---|--------|----------|-----------------|-----------------|
| 1 | Root CA rotasyon runbook’u yok | Basit idare | Root **10y** + Intermediate **5y** (bootstrap); leaf **90g**; hatırlatma yeterli | 10y praktikte rotasyon = gelecek işi; otomatik CA döngüsü aşırı |
| 2 | CRL/OCSP kurulu değil; PKI cert revoke **task/script yok** | Kabul | 90g leaf + auto-renew; sızıntıda elle `bao …/revoke serial=…`; mount `bao secrets list` | Tam CRL + orkestrasyon = aşırı mühendislik |
| 3 | Credential lifecycle: `secret_id_ttl` yok; revoke job yok | TTL ile idare | Token **15dk–24s**; policy dar; app-remove CR/Secret siler; asılı token TTL ile ölür | Ayrı token/secret orkestrasyonu homelab’de gereksiz |
| 4 | OpenBao tek LXC (SPOF) | Kabul | `backup-openbao.sh` raft snapshot (restic, üç seri) + `restore.sh` + DR runbook'ı | 3-node HA / dış KMS simülasyon dışı |
| 5 | Upgrade sonrası sealed riski | Basit idare | Öncesi snapshot + `unseal.sh`; DR benzeri adımlar | Auto-unseal opsiyonel; SoftHSM ek katmanı şimdilik gerekmez |
| 6 | Intermediate key ayrı export yedeği yok | Tasarım gereği | Raft + disk yedeği yeter; internal key dışarı çıkmaz | Ayrı key-archive / HSM = aşırı |
| 7 | Paylaşımlı wildcard yüzeyi | Kabul + mevcut araç | İç ağda `*.tofu.lan`; gerektiğinde **dedicated** Certificate (zaten mimari) | Her servise enterprise PKI süreci değil |
| 8 | cert-manager `secret_id` otomatik rotasyonu yok | Basit idare | `openbao-ops` playbook tekrarı Secret’ı yeniler; auth zaten AppRole + `secretRef` | Sürekli dönen rotasyon döngüsü gereksiz karmaşıklık |
| 9 | Backup RPO'su ortam kararına bağlı; `encryption.key` yedeği yok | Basit idare | Zamanlama ve `keep-last` role tanımlı (`docs/tr/maintenance/maintenance.md`); unseal key ile `encryption.key` **yedek zincirinin dışında** | Özel backup platformu kurulmuyor |

---

## 1. Root CA rotasyon runbook’u yok

| | |
|--|--|
| **Kısıt** | Root süresi dolduğunda / Intermediate yenilenirken yazılı runbook yok (`docs/pki-rotation.md` yok). |
| **Yaklaşım** | Basit idare |
| **Pratik karşılık** | TTL’ler kodda hazır: Root `87600h` (~10y), Intermediate `43800h` (~5y), leaf `2160h` (90g) — `openbao` security/ops defaults + `bootstrap.yml`. Intermediate imzalama **bootstrap akışında** var. Gerektiğinde tek sayfa not + takvim hatırlatması. |
| **Gerekçe** | 10y Root’da otomatik rotasyon döngüsü, offline Root, portal vb. homelab’de aşırı mühendislik. |

---

## 2. CRL/OCSP yok; sertifika revoke otomasyonu yok

| | |
|--|--|
| **Kısıt** | Gateway/Ingress seviyesinde CRL/OCSP yok. Ansible/script’te PKI **cert revoke** task’ı yok (app-remove’da da yok). |
| **Yaklaşım** | Kabul |
| **Pratik karşılık** | Leaf **90 gün** + cert-manager auto-renew. Sızıntı şüphesinde OpenBao API yeterli (elle 1 satır): `bao write <mount>/revoke serial_number=…` (mount: `bao secrets list`). CRL üretilse de homelab edge’inde consume edilmez. |
| **Gerekçe** | Tam CRL/OCSP dağıtımı + policy point = operasyon yükü; kısa ömür riski zaten daraltıyor. |

**İlişkili (ayrı):** app-remove **sertifika CR/Secret** siler; OpenBao’ya revoke
**gitmez** — CR silme CRL yazmaz. Lifecycle ≠ cert revoke.

---

## 3. Credential lifecycle: kısa token; `secret_id` TTL bilinçli yok

| | |
|--|--|
| **Kısıt** | Rol body’lerinde `secret_id_ttl` / `secret_id_num_uses` **tanımlı değil** (`openbao-rbac.md` §11: bilinçli erteleme). Ayrı revoke job yok. |
| **Yaklaşım** | Token TTL |
| **Pratik karşılık** | **Token süreleri** (`openbao/security/defaults` → `openbao_workload_profiles` + platform rolleri): workload geneli **15dk–1s** (ör. `transit-user` / `job-run`: **30dk / max 1s**, batch); `metrics-reader` / `reader`: **1s / 24s** service. `token_num_uses: 0` → süre sınırı, kullanım hakkı açık. Yetki **policy + scope** ile dar. app-remove: K8s objeler + TLS Secret siler; asılı token **TTL ile biter**. Platform (`cert-manager`, `k8s-csi`): **1s / 24s**; `openbao-ops` her koşuda taze `secret_id` üretir. |
| **Gerekçe** | Anında token kill, accessor envanteri, dönen `secret_id` rotasyonu = fazla hareketli parça; homelab’de TTL + dar policy yeterli. |

**Dipnot (açık):** §7 workload remove, rol adı `app-<scope>-<profile>` silmeye
çalışır; üretim **profil adlı** rol (`transit-user` vb.) kullandığından DELETE
çoğu zaman **404 no-op** olur — profil rolü paylaşımda kalır (doğru).
Yani “rol siliniyor → secret_id süpürülüyor” cümlesi **her workload için
geçerli değil**; scope KV girdisi / `outputs/*-approle.json` temizliği de
ayrı teyit konusudur. İstenirse ileride: `secret_id_ttl` (ör. 24–72s)
**veya** remove’da accessor destroy — ikisi de opsiyonel.

---

## 4. OpenBao tek nokta arıza (SPOF)

| | |
|--|--|
| **Kısıt** | Tek LXC: PKI + secret store birlikte düşer. |
| **Yaklaşım** | Kabul |
| **Pratik karşılık** | Raft: `openbao_storage_type: raft` → `/var/lib/bao/raft`. Uygulama yedeği: `maintenance/backup/app-data/backup-openbao.sh` → restic → `openbao-daily` / `-weekly` / `-monthly` kovaları (Garage2, kova başına `keep-last 3`); ayrıca OpenBao'nun kendi diskinde 7 günlük yerel kopya. Disk görüntüsü: `maintenance/backup/vm-disk/backup-full.sh` (haftalık, PVE local). Kurtarma elle yapılır: `maintenance/restore/restore.sh` (bkz. `docs/tr/maintenance/disaster-recovery.md`). Değişiklik öncesi manuel `pct` snapshot. **Snapshot ≠ backup** (aynı disk). |
| **Gerekçe** | 3-node Raft cluster, dış KMS, active-active = kurulum/ bakım maliyeti homelab’i aşar; risk bilinçli kabul (`master-design` §10). |

---

## 5. Upgrade sonrası sealed riski

| | |
|--|--|
| **Kısıt** | Binary/OS upgrade restart → sealed; ayrı tek sayfa upgrade runbook’u yok. |
| **Yaklaşım** | Basit idare |
| **Pratik karşılık** | Öncesi raft/disk snapshot → upgrade → `scripts/openbao-unseal/unseal.sh` → `bao status` + `bao secrets list`. Unseal key **backup’tan ayrı** (password manager). Auto-unseal: `extra-samples/openbao-auto-unseal/` (default **kapalı**, opsiyonel). |
| **Gerekçe** | PKCS#11 SoftHSM auto-unseal’ı kurmak ayrı stack; ve fiziksel bir anahtar değil yazılımsal olduğu için aslında proje ölçeğinde anlamsız olup guvenlik sağlamaz, şimdilik elle unseal + snapshot yeterli. |

---

## 6. Intermediate / Root private key ayrı yedek yok

| | |
|--|--|
| **Kısıt** | Key’ler için “export edip offsite sakla” akışı yok (istemiyoruz). |
| **Yaklaşım** | Tasarım gereği |
| **Pratik karşılık** | `internal` key mod → OpenBao dışına çıkmaz; raft snapshot + disk yedeği mount’ları (şifreli) kapsar. Unseal key ayrı kanalda. |
| **Gerekçe** | Ayrı key-archive, ikinci HSM, air-gap Root = aşırı mühendislik; golden rule: unseal key ≠ aynı backup zinciri. |

---

## 7. Paylaşımlı wildcard sertifika

| | |
|--|--|
| **Kısıt** | `*.tofu.lan` tek yüzey (`gateway-tls`). |
| **Yaklaşım** | Kabul + mevcut araç |
| **Pratik karşılık** | İç ağ + 90g auto-renew. Ayrı sertifika isteyenler için **dedicated** yol zaten mimaride (`tls.mode: dedicated`, `dedicated-pki-domains.yml`, app namespace Certificate + ListenerSet). Dışarıya açık servis yoksa ek CR = fazladan iş. |
| **Gerekçe** | Her app için ekstra sertifika politikası; sadece ihtiyaç olan dedicated. |

---

## 8. cert-manager auth — method net; otomatik `secret_id` rotasyonu yok

| | |
|--|--|
| **Kısıt** | cert-manager AppRole `secret_id`’si otomatik dönmez (döngü yok). |
| **Yaklaşım** | Basit idare |
| **Pratik karşılık** | Method **uygulanmış**: `openbao-ops` role_id + secret_id → Secret `cert-manager-approle`; `cluster-issuer.yaml.j2` `auth.appRole` + `secretRef`. Yenileme: playbook’u tekrar çalıştırmak. Statik token kullanılmaz. |
| **Gerekçe** | CSI `secretObjects` sync veya saatlik rotasyon = extra moving part; homelab’de playbook tekrarı yeterli (rehber §11.2). |

---

## 9. Backup: sıklık ve kanallar (homelab şablonu)

| Bileşen | Yöntem | Sıklık (pratik) | Not |
|---------|--------|-----------------|-----|
| Garage LXC (state) | Disk / `backup-full.sh` (`vzdump`) | Haftalık (PVE host cron) | Yalnızca PVE local; flat 28 gün + weekly 3 / monthly 3. Tofu state deposu (`opentofu-state`) |
| Garage2 LXC (backup) | restic repoları (kova = depo) | 4 saatte bir + haftalık + aylık | Uygulama yedeklerinin **tek deposu** |
| OpenBao LXC | `backup-openbao.sh` (raft) | 4 saatte bir (`openbao-daily`) + Pazar (`-weekly`) + ayın 1'i (`-monthly`) | restic → Garage2, kova başına `keep-last 3`; diskte 7 günlük yerel kopya |
| K8s Master | `backup-etcd.sh` (etcd snapshot) | 4 saatte bir (`etcd-daily`) + Pazar + ayın 1'i | restic → Garage2; `keep-last 12` / 3 / 3 |
| Worker VM'ler | Yok | — | Stateless; Tofu yeniden kurar |
| `encryption.key` | **Yok** | — | Controller'da iki kopya, **aynı disk**; offsite yok |
| Unseal key | **Yok** | — | Password manager; yedekleme kanalının dışında |

State taşıyan üç yer: **Garage (state), OpenBao, etcd/master**. Worker ve pod yedeklemek zaman kaybıdır.

**İki ayrı Garage LXC vardır:** state deposu ile backup deposu birbirinden
ayrıdır; restic kovaları yalnızca Garage2'de durur. Zamanlama, `keep-last` ve
tazelik eşiği (`interval_h` / `tolerance_h`) `ansible/roles/maintenance` içinde
tanımlıdır — tetikleme **systemd timer**'ıdır (cron değil).

> **CT ID'ler kuruluma özgüdür.** Garage LXC'lerinin kimliği `chef.sh --ctid`
> ile belirlenir (boş bırakılırsa `scripts/garage-setup/.garage-setup.env`
> okunur); Tofu yönetimindeki LXC'lerin kimliği
> `tofu/environments/<env>/*.tfvars` içindeki `ct_id` ile verilir (ör. laws: 302),
> verilmediyse Proxmox otomatik numara atar. Belgede geçen değerler
> **örnektir** — ayrıntı için bkz. `docs/tr/maintenance/maintenance.md` §2.

**Bilinen sınır:** Garage2 tek LXC'dir ve altı restic reposunun tamamı onda
durur; bu LXC'nin kaybı altı uygulama yedeğini de götürür. Host-dışı kopya
(`restic copy`) planlanmış, uygulanmamıştır.

---

## Kapsam dışı (bu listede taşımıyoruz)

| Konu | Nereye |
|------|--------|
| Cilium `k8s:` prefix sessiz atlanması | Standart davranış → `master-design.md` §8.4 |
| Yedekleme mimarisi, restic repoları, timer | `docs/tr/maintenance/maintenance.md` |
| Yedekleme akışı + DR adımları | `master-design.md` §10, `docs/tr/maintenance/disaster-recovery.md` |
| OpenBao motor / olgunluk tablosu | `docs/tr/openbao/openbao-architecture-guide.md` §11.2 |
