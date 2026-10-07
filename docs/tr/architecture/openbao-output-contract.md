# OpenBao Output Sözleşmesi

Bu doküman OpenBao server, openbao-ops ve k8s_apps play’leri arasındaki output sözleşmesini tanımlar. Amacı `openbao.ip` değişkenine olan bağımlılığı kaldırmak ve IP/Port bilgisinin inventory’den türetilerek output dosyalarına yazılmasını sağlamaktır.

## Dosya Yerleri

* `outputs/openbao/openbao-credentials.yml` - root token ve unseal keys
* `outputs/openbao/openbao-unseal-keys.txt` - insan okunabilir özet
* `scripts/openbao-unseal/credentials.txt` - unseal script için HOST/PORT
* `outputs/openbao/openbao-config.json` - sunucu bağlantı bilgisi
* `outputs/openbao/openbao-mount.json` - mount isimleri ve adres
* `outputs/openbao/pki-manager.json` - k8s_apps dedicated-PKI yöneticisi (P2) AppRole credentials
* `outputs/openbao/ops-admin.json` - operasyonel işler (P4) AppRole credentials
* `outputs/openbao/monitor.json` - izleme/telemetri okuyucusu AppRole credentials
* `outputs/openbao/bao-raft-agent.json` - raft snapshot agent'ı (B10, salt okuma) AppRole credentials
* `outputs/openbao/bao-raft-restore.json` - raft geri yükleme (B10+B11, yazma) AppRole credentials

Son beş dosya `roles/openbao/security/defaults/main.yml` içindeki
`openbao_platform_credentials` listesinden **veri güdümlü** olarak üretilir; liste
büyürse yeni rolün `.json` dosyası otomatik üretilir.

## openbao-config.json

Server init başarılı olduğunda `roles/openbao/server/tasks/init.yml` tarafından üretilir.

```json
{
  "host": "164.102.98.186",
  "port": 8200,
  "address": "https://164.102.98.186:8200",
  "generated_at": "2026-09-06T12:00:00Z",
  "openbao_version": "2.6.2"
}
```

`host` değeri `hostvars[groups.openbao[0]].ansible_host` üzerinden türetilir. `port` defaults’tan alınır.

## openbao-mount.json

OpenBao server bootstrap aşamasında `roles/openbao/server/tasks/bootstrap.yml` tarafından üretilir (rbac-platform.yml ile birlikte root token'dan çalışır).

```json
{
  "approle_mount": "approle",
  "transit_mount": "transit",
  "pki_mount": "pki",
  "pki_int_mount": "pki-int",
  "kv_mount": "secret",
  "address": "https://164.102.98.186:8200",
  "generated_at": "2026-09-06T12:00:00Z",
  "openbao_version": "2.6.2"
}
```

`use_default_mounts` true ise mount isimleri OpenBao server bootstrap'inin ürettiği `outputs/openbao/openbao-mount.json` içinden alınır. False ise `group_vars/all/all.yml` içindeki manuel değerler kullanılır.

## AppRole credentials (pki-manager, ops-admin, monitor, bao-raft-agent, bao-raft-restore)

`roles/openbao/security/tasks/rbac-platform.yml` bootstrap içinden root token'la üretilir
(`openbao_platform_credentials` listesindeki her rol için):

```json
{
  "role_id": "…",
  "secret_id": "…"
}
```

Dosyalar `0600` izniyle ve `no_log: true` ile yazılır. Tüketimleri:


- `ops-admin.json` — operasyonel roller (openbao-ops) her koşuda bu dosyadan login yapar; root token bu rol içinde asla kullanılmaz (openbao-rbac.md §6.2).

- `pki-manager.json` — dedicated-PKI rol yönetimi (openbao-rbac.md §3, P2) okuyucusu.
- `monitor.json` — Prometheus/telemetri okuma profili.
- `bao-raft-agent.json` — `roles/openbao/server/tasks/backup.yml` bu çifti
  `/etc/bao/snap-bao-raft-agent-roleid` ve `snap-bao-raft-agent-secretid` olarak
  dağıtır (`0640 bao:bao`); `bao agent` bunları `auto_auth` ile okur.
  Politika **salt okuma** (B10) — 7/24 açık servis raft deposunu geri yazamaz.
- `bao-raft-restore.json` — aynı task `snap-bao-raft-restore-roleid` /
  `snap-bao-raft-restore-secretid` olarak dağıtır; `maintenance/restore/restore-openbao.sh`
  bunlarla **tek seferlik** AppRole login yapar (token diske yazılmaz).
  Politika B10+B11 — geri yükleme yazma yetkisi taşır.

## Tüketim

* `roles/k8s-apps/app-deploy/tasks/dedicated-pki-domains.yml` önce dedicated talep olup olmadığını kontrol eder.
* Talep varsa `outputs/openbao/openbao-mount.json` ve `outputs/openbao/pki-manager.json` okunur.
* `roles/openbao/server/tasks/backup.yml` raft profilinin `.json` çiftini okur ve
  `/etc/bao/` altına dağıtır; dosya yoksa play **fail-fast** ile durur
  (`openbao_backup_enabled: true` iken).
* Dosya yoksa play fail olur ve `openbao.yml` (bootstrap → rbac-platform) çalıştırılması istenir.


## Versiyonlama

`generated_at` RFC3339 UTC formatında tutulacak. K8s Apps tarafında dosya yaşı kontrolü 30 gün olarak önerilir.
