# OpenBao Testleri

> Kapsam: OpenBao ile ilgili **tüm canlı doğrulama testleri** — prosedür (komut +
> beklenen + sonuç) ve gerçek çıktı. Mimari anlatım ve kanıt logu ilgili ana
> dokümandadır; burada yalnız test prosedürleri tutulur.
>
> **Bu belge yeni bölümler için şablon görevi görür.** Yeni konu eklemek için:
> `## Bölüm N — <konu>` başlığı → `### Önkoşullar` → her test için
> `### Test M — <kontrol edilen şey>` ve altında **soru / komut / Beklenen /
> Sonuç (YYYY-MM-DD)**. Test numaraları belge genelinde kesintisiz devam eder
> (Bölüm 1: Test 1-4, Bölüm 2: Test 5-13, Bölüm 3: Templating pilotu).

## Bölüm 1 — Transit Envelope Motor ve İşlem (F2.6)

> Kapsam: `transit-envelope-b` Job'unun canlı doğrulama prosedürleri ve sonuçları.
> Mimari anlatım ve kanıt logu `openbao-architecture-guide.md §6.2`'dedir; burada prosedür (komut + beklenen + sonuç) tutulur.

### Önkoşullar

- Job koşmuş ve `ENVELOPE PASS` vermiş olmalı (`kubectl -n transit-demo logs job/transit-envelope-b`).
- Admin token (ops-admin AppRole, controller'dan):
  ```bash
  cd ansible
  ROLE=$(jq -r .role_id outputs/openbao/ops-admin.json)
  SECRET=$(jq -r .secret_id outputs/openbao/ops-admin.json)
  ADMIN=$(curl -sk -X POST https://164.102.98.186:8200/v1/auth/approle/login \
    -d "{\"role_id\":\"$ROLE\",\"secret_id\":\"$SECRET\"}" | jq -r .auth.client_token)
  ```

### Test 1 — Negatif 403

Yetkisiz çözme isteği engelleniyor mu?

```bash
curl -sk -X POST https://164.102.98.186:8200/v1/transit/decrypt/transit-envelope-b-app-key \
  -d '{"ciphertext":"vault:v1:AAA"}' -w "\nHTTP:%{http_code}\n"
```

- Beklenen: `{"errors":["permission denied"]}`, HTTP 403.
- Sonuç (2026-09-16): ✅ `permission denied`, HTTP 403.

### Test 2 — Audit'te plaintext yok

Hassas veri audit diske yazılmıyor mu? (LXC CT 301 üzerinde.)

```bash
grep -c "transit-demo-B-envelope" /var/log/bao/audit.log
# Beklenen: 0
grep "datakey" /var/log/bao/audit.log | head -3
# Beklenen: istek satırları var; token/plaintext/ciphertext alanları hmac-sha256 ile maskeli
```

- Sonuç (2026-09-16): ✅ sayı 0; secret alanları maskeli.
- Bonus kanıt: `metadata.scope: transit-envelope-b`, `token_type: batch, ttl: 1800` — profil kataloğuyla birebir.

### Test 3 — Rotate

Anahtar dönünce eski zarflar yaşıyor mu?

```bash
curl -sk -o /dev/null -w "rotate HTTP:%{http_code}\n" -X POST \
  https://164.102.98.186:8200/v1/transit/keys/transit-envelope-b-app-key/rotate \
  -H "X-Vault-Token: $ADMIN"
# Beklenen: rotate HTTP:200

curl -sk https://164.102.98.186:8200/v1/transit/keys/transit-envelope-b-app-key \
  -H "X-Vault-Token: $ADMIN" | jq .data.latest_version
# Beklenen: 2

curl -sk -X POST https://164.102.98.186:8200/v1/transit/decrypt/transit-envelope-b-app-key \
  -H "X-Vault-Token: $ADMIN" -d '{"ciphertext":"<eski-wrapped>"}' \
  | jq -r '.data.plaintext | length'
# Beklenen: 44 (= base64(32B) — eski zarf çözüldü)
```

- Sonuç (2026-09-16): ✅ HTTP 200, `latest_version: 2`, eski wrapped çözüldü (44).

### Test 4 — İkinci koşu idempotency

Tekrar koşuda üzerine yazma olmuyor mu?

```bash
ansible-playbook -i inventory/k8s.ini.generated playbooks/k8s_apps.yml --tags apps
```

- Beklenen: `Scope 'transit-envelope-b' zaten OpenBao KV'de mevcut, OpenBao adımları atlanıyor` + `failed=0`.
- Sonuç: ✅ beklenen uyarı basıldı, OpenBao adımları atlandı, `failed=0` (kullanıcı koşumlarında defalarca gözlemlendi).

---

## Bölüm 2 — Raft Snapshot Agent (B10/B11)

> Kapsam: `bao-raft-agent` servisinin canlı doğrulaması. Yetki tanımı
> `openbao-rbac.md §3` (P5/B10 + P6/B11), config/unit
> `roles/openbao/server/templates/bao-raft-agent.{hcl,service}.j2`,
> dağıtım `roles/openbao/server/tasks/backup.yml`.
>
> ℹ️ **Beklenen sütunu hakkında:** Bu bölüm hata ayıklaması sırasında, düzeltme
> *sonrası* yazıldı. Yani "Beklenen" değerleri gözlemden geriye doğru
> türetildi. Bu bölümün regresyon değeri `Beklenen` satırındadır: bir sonraki
> kurulumda sapma olursa burası kıyas noktasıdır.

### Önkoşullar

- `openbao_backup_enabled: true` (varsayılan) ve `roles/openbao/server/tasks/backup.yml` koşmuş olmalı → `bao-raft-agent.service` + `/etc/bao/agent.sock`.
- CT 301 = `openbao-1` = `164.102.98.186`. LXC yönetimi `root` + `~/.ssh/id_ed25519`.
- **Hiçbir komutta token kullanılmaz.** Agent'ın `api_proxy` + `auto_auth`
  yetkisi devreye girer; token'ı yalnız agent bilir.
- Kolaylık için agent soketi üzerinden çalışan `bao` istemcisi kullanılır:
  ```bash
  export BAO_ADDR=unix:///etc/bao/agent.sock
  export BAO_SKIP_VERIFY=true
  B=/usr/local/bin/bao
  ```
  (`BAO_SKIP_VERIFY` şart: sunucu TLS'i `openssl req -x509` ile **kendinden
  imzalı** — `configure.yml:2`. Aynı değişken `init.yml`'de de kullanılıyor.)

### Test 5 — Servis etkin ve etkinleştirilmiş mi?

Unit kuruldu mu, açılışta da çalışacak mı?

```bash
systemctl is-active bao-raft-agent
systemctl is-enabled bao-raft-agent
```

- Beklenen: `active` ve `enabled`.
- Sonuç (2026-09-28): ✅ `active` / `enabled`.

### Test 6 — Socket oluşmuş mu, sahibi kim?

Unix listener gerçekten dosyayı yaratabiliyor mu? (`ProtectSystem` regresyon
noktası — aşağıdaki "Bilinen hata" bölümüne bak.)

```bash
ls -l /etc/bao/agent.sock
```

- Beklenen: socket dosyası var, sahibi `bao:bao`.
- Sonuç (2026-09-28): ✅ `srwxr-xr-x 1 bao bao 0 Sep 28 12:19 /etc/bao/agent.sock`

### Test 7 — Token'siz bağlantı (auto_auth çalışıyor mu?)

Token taşımadan, yalnız soket üzerinden OpenBao'ya ulaşılabiliyor mu?

```bash
BAO_ADDR=unix:///etc/bao/agent.sock BAO_SKIP_VERIFY=true /usr/local/bin/bao status
```

- Beklenen: `Sealed: false`, `Initialized: true` — **token yok**.
- Sonuç (2026-09-28): ✅
  ```
  Key                     Value
  ---                     -----
  Seal Type               shamir
  Initialized             true
  Sealed                  false
  Total Shares            5
  Threshold               3
  Version                 2.6.2
  ```

### Test 8 — Auto-auth ve yenileme (journal kanıtı)

Kimlik alındı mı, yenileme döngüsü kuruldu mu? `Type=notify` ile restart
başarılı olması da dolaylı kanıttır (agent `READY=1` göndermeden unit
`active` olmaz).

```bash
journalctl -u bao-raft-agent --no-pager -n 12 \
  | grep -iE "auth|error|warn|listener|ready|token"
```

- Beklenen: `authentication successful` + `starting renewal process` +
  `renewed auth token`.
- Sonuç (2026-09-28): ✅
  ```
  Sep 28 12:19:24 openbao-1 bao[8059]: [INFO]  agent.auth.handler: authenticating
  Sep 28 12:19:24 openbao-1 bao[8059]: [INFO]  agent.auth.handler: authentication successful, sending token to sinks
  Sep 28 12:19:24 openbao-1 bao[8059]: [INFO]  agent.auth.handler: starting renewal process
  Sep 28 12:19:24 openbao-1 bao[8059]: [INFO]  agent.auth.handler: renewed auth token
  ```
- Not: Yenileme `bao agent` içindedir; `backup-openbao.sh` içinde **hiç token
  yenileme kodu yoktur**. Uzun ömürlü/süresiz token talebi bu yüzden
  karşılanmaz (bkz. `openbao-rbac.md §3` — süresiz tokenı yalnız root üretir).

### Test 9 — P5 READ: profil raft snapshot okuyabiliyor mu?

`bao-raft-agent` politikasında `sys/storage/raft/snapshot` → `read` vardır.

```bash
BAO_ADDR=unix:///etc/bao/agent.sock BAO_SKIP_VERIFY=true \
  /usr/local/bin/bao read sys/storage/raft/snapshot
```

- Beklenen: yetkilendirme **geçer**; sunucu raft verisini döndürür.
- Sonuç (2026-09-28): ✅
  ```
  Error reading sys/storage/raft/snapshot: invalid character '\x1f' looking for beginning of value
  ```
- ⚠️ **Bu PASS'tir, hata değil.** Raft snapshot **sıkıştırılmış ikili
  akıştır**; `0x1f` gzip sihirli numarasının (`1f 8b`) ilk baytıdır. Yani
  sunucu veriyi döndürdü, CLI yalnız JSON'a çeviremedi. **Beklenen davranış tam
  olarak bu çıktıdır** — yetki reddi olsaydı `403 permission denied` görünürdü.

### Test 10 — P5 WRITE: profil yazamıyor mu? (asıl uyum testi)

En kritik kontrol. 7/24 açık servis raft deposunu **geri yazamamalı**.

```bash
BAO_ADDR=unix:///etc/bao/agent.sock BAO_SKIP_VERIFY=true \
  /usr/local/bin/bao write sys/storage/raft/snapshot path=/tmp/conformance-probe.snap
```

- Beklenen: `403 permission denied` (PASS = reddedildi).
- Sonuç (2026-09-28): ✅
  ```
  Error writing data to sys/storage/raft/snapshot: Error making API request.

  URL: PUT http://localhost/v1/sys/storage/raft/snapshot
  Code: 403. Errors:
  ```
- Not: Profil yazabilseydi bu komut bir snapshot **yaratırdı** — yani yetki
  hatası veri bozulması değil, sessiz fazla yetki olarak görünürdü.

### Test 11 — Token kataloğu: hangi politikalar?

```bash
BAO_ADDR=unix:///etc/bao/agent.sock BAO_SKIP_VERIFY=true \
  /usr/local/bin/bao token lookup | grep -iE "policies|renewable|display_name"
```

- Beklenen: politikalar `[bao-raft-agent default]`, yenilenebilir.
- Sonuç (2026-09-28): ✅
  ```
  display_name         approle
  policies             [bao-raft-agent default]
  renewable            true
  ```
- Not: `default` politikası OpenBao'nun her tokena otomatik eklediği
  **boş (deny-by-default)** politikadır. Aşağıdaki Test 12 bunu kanıtlar.

### Test 12 — `default` politikası boş mu? (deny-by-default kanıtı)

`default` politikasında gizli yetki var mı?

```bash
BAO_ADDR=unix:///etc/bao/agent.sock BAO_SKIP_VERIFY=true \
  /usr/local/bin/bao policy read default
```

- Beklenen: `403` — politika okunamaz, yani yetki taşımıyor.
- Sonuç (2026-09-28): ✅
  ```
  Error reading policy named default: Error making API request.

  URL: GET http://localhost/v1/sys/policies/acl/default
  Code: 403. Errors:

  * 1 error occurred:
  	* permission denied
  ```

### Test 13 — `socket_mode` gerçekten uygulanıyor mu? (Beklenmeyen bulgu)

Config'de `socket_mode = "0660"` yazılı. Fiilen ne oluyor?

```bash
stat -c '%n  mode=%A  octal=%a  owner=%U:%G' /etc/bao/agent.sock
stat -c '%n mode=%a owner=%U:%G' /etc/bao
systemctl show bao-raft-agent -p UMask --value
```

- Beklenen: socket `0660`.
- Sonuç (2026-09-28): ❌ **socket `0755`** — agent `socket_mode`'u **uygulamıyor**.
  ```
  /etc/bao/agent.sock  mode=srwxr-xr-x  octal=755  owner=bao:bao
  /etc/bao mode=750 owner=bao:bao
  0022
  ```
  `0755` = `0777 & ~umask(0022)`, yani socket **modu hiç uygulanmadan**
  varsayılan olarak oluşturulmuş.
- **Güvenlik yine yeterli, ama farklı gerekçeyle:** socket'in bulunduğu dizin
  `/etc/bao` = `0750 bao:bao`. Dizine yalnız `root` ve `bao` grubu girebildiği
  için socket'a erişim fiilen kısıtlı.
- 🔴 **Sonuç: bugün koruma DİZİN izninden geliyor, `socket_mode`'dan değil.**
  `/etc/bao` 0750'tan düşülürse socket de açılır. `bao-raft-agent.hcl.j2`
  yorumu bu ölçümle güncellendi.
- Doğrulama kaynağı: `openbao.org/docs/configuration/listener/unix` →
  `socket_mode (string: "", <optional>)` — tip doğru, tip sorunu değil;
  davranış openbao 2.6.2'de eksik.

### Bilinen hata ve kök neden (regresyon notu)

Bu bölümdeki testler, aşağıdaki arızanın giderilmesiyle mümkün oldu. Aynı
düzeltmeler yeniden uygulanırsa servis ayakta olmaz.

**Belirti:** `bao-raft-agent.service` sürekli restart döngüsünde, her denemede

```
bao[...]: Error fetching client: failed to get token helper: open /home/bao/.bao: permission denied
systemd[1]: bao-raft-agent.service: Main process exited, code=exited, status=1/FAILURE
```

**Kök neden — üçü de `bao.service`'ten kopyalanan hardening bloğundan:**

| # | Neden | Belirti | Düzeltme |
|---|---|---|---|
| 1 | `ProtectHome=yes` → `/home` mount namespace'de erişilemez. `bao agent` client kurarken CLI config dizinini (`$HOME/.bao`) okur → `EACCES` → `exit 1` | log'daki **ilk** hata | `ProtectHome=yes` **silindi** |
| 2 | `ProtectSystem=full` → `/etc` salt-okunur → unix listener `/etc/bao/agent.sock` dosyasını **yazamaz** | 1. düzeltilince ortaya çıkar | `ProtectSystem=full` + `ReadWritePaths=` **silindi** |
| 3 | Sunucu TLS'i `openssl req -x509` ile kendinden imzalı; agent config'inde `tls_skip_verify`/`BAO_SKIP_VERIFY` yok | 2. düzeltilince ortaya çıkar | `Environment=BAO_SKIP_VERIFY=true` **eklendi** |

**Neden 1'in yalnız agent'ta patladığı:** `bao server` `~/.bao` dizinine hiç
dokunmaz — problem oluşturmaz. `bao agent` ise client kurarken okumak zorundadır.
Resmi `openbao-snapshot-agent` unit'inde (`docs/vm-configuration.md`) bu üç
sertleştirme satırının **hiçbiri yok**; yalnız `NoNewPrivileges`, `PrivateTmp`,
`LimitNOFILE` benzeri dosya sistemini etkilemeyen yönler korunmuştur.

**Düzeltme sonrası doğrulama:**

```bash
grep -nE '^(Protect|ReadWrite)' /etc/systemd/system/bao-raft-agent.service
# Beklenen: çıktı boş (sertleştirme yok)
grep -E 'NoNewPrivileges|PrivateTmp|LimitNOFILE' /etc/systemd/system/bao-raft-agent.service
# Beklenen: üçü de mevcut
grep BAO_SKIP_VERIFY /etc/systemd/system/bao-raft-agent.service
# Beklenen: Environment=BAO_SKIP_VERIFY=true
```

Playbook sonucu (2026-09-28):

```
localhost                  : ok=2    changed=0    unreachable=0    failed=0    skipped=3    rescued=0    ignored=0
openbao-1                  : ok=86   changed=19   unreachable=0    failed=0    skipped=23   rescued=0    ignored=0
```

---

## Bölüm 3 — Identity Templating Pilotu (2026-09-10)

> Amaç: `identity.entity.aliases.<accessor>.metadata.scope` tabanlı politika şablonlarının canlı doğrulanması. Kapsamlı referans: [`openbao-rbac.md`](openbao-rbac.md) §5.

### Önkoşullar

- OpenBao 2.6.2 ayakta ve unsealed; `ops-admin` credential'ı controller'da mevcut.
- Pilot kaynaklar (rol, policy, KV verisi) test sonunda tamamen silinir.

### Test P-1 — Alias metadata görünürlüğü

`transit-demo` rolünde `metadata='{"scope": "pilot-app"}'` (JSON-string) ile secret-id üretildi, login olundu, `identity/entity` okundu.

- **Beklenen:** alias metadata içinde `scope: pilot-app` görünür.
- **Sonuç (PASS):** `{'role_name': 'transit-demo', 'scope': 'pilot-app'}` — custom metadata alias'a kopyalanıyor; templating kullanılabilir.
- **Temizlik:** secret-id `secret-id-accessor/destroy` ile silindi. Not: `secret-id/destroy` accessor kabul etmez ("missing secret_id" verir); `revoke-self` 204 boş döner.

### Test P-2 — Tek statik policy ile kapsam izolasyonu

Tek `workload-reader-templated` politikası + iki pilot rol (`rbac-pilot-a/b`, TTL 10m) + KV test verileri.

- **Beklenen (4 kontrol):** A→kendi 200, A→B 403, B→kendi 200, B→A 403.
- **Sonuç (PASS):** 4/4 tuttu.
- **Düzeltme (canlı yakalandı):** `sys/auth` accessor'ı önekli döner (`auth_approle_<id>`). HCL anahtarına ek `auth_approle_` öneki konursa anahtar `auth_approle_auth_approle_<id>` olur ve policy sessizce 403 verir (pozitif test dahil). Doğru anahtar = accessor'ın kendisi; Ansible fact'i `regex_replace('^auth_approle_', '')` ile yalınlaştırır.
- **Temizlik:** token revoke + secret-id destroy + rol/policy/KV silme (tam).

### Kaynak araştırma notu — OpenBao Discussion #2212

Yukarı akış tartışması (Aralık 2025, kapalı) ile kanıtlanan/kanıtlanmayan ayrımı:

- **Kanıtlanan:** `entity.name` AppRole'da çalışmaz (403, transkriptli); çalışan form mount accessor'ını literale gömer (mount bakım yükü); template instantiation'ların debug yolu yok (collaborator eyenx teyitli); önerilen desen her approle için kodla policy üretmek (= projenin render-tasarımı).
- **Kanıtlanmayan:** tartışmadaki secret-id'ler metadata'sız üretildi (`-force`, parametresiz) — görünen `role_name` login mekanizmasının otomatik yazdığı değerdir; custom `scope` metadata'sının alias'a kopyalandığı bu kayıttan çıkmaz. Bu boşluğu Test P-1 kapattı.
