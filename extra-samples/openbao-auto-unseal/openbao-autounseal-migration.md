# OpenBao — Elle Unseal'dan Auto-Unseal'a Geçiş (PKCS#11 / SoftHSM2)

Mevcut durum: `bao-config.hcl.j2`'de `seal` bloğu tanımlı değil → varsayılan **Shamir seal** kullanılıyor → her restart'ta elle unseal gerekiyor. Bu runbook, plugin-tabanlı PKCS#11 seal'e (SoftHSM2 ile) geçişi anlatır. Built-in `seal "pkcs11"` **kullanılmıyor** çünkü OpenBao 2.7.0'da built-in PKCS11 seal kaldırılıyor, sadece plugin olarak kalıyor — bu runbook baştan 2.7 uyumlu.

> **Dürüst tehdit modeli notu:** SoftHSM2 gerçek bir donanım HSM değil, PKCS#11 arayüzünün yazılım simülasyonudur — anahtar disk üzerinde bir dosyada durur. Bu runbook'ta OpenBao ile **aynı LXC'ye** kurulduğu için, disk'e tam erişimi olan biri hem şifreli Raft verisine hem onu açacak anahtara aynı anda ulaşır. Yani bu kurulum **ek bir güvenlik katmanı sağlamaz** — sağladığı şey sadece "her restart'ta elle unseal etmeyeyim" rahatlığıdır. Gerçek ek güvenlik isteniyorsa aşağıdaki **§9 — Alternatif Mimariler** bölümüne bakın.

> **Ön koşul:** Raft kullandığınız için (`openbao_storage_type = raft`) migration sırasında ekstra bir storage riski yok — ama yine de aşağıdaki adım 1'i atlamayın.

---

## Adım 1 — Migrasyon öncesi backup (zorunlu)

```bash
bao operator raft snapshot save /root/pre-autounseal-migration.snap
```

Bu, mevcut `bao-backup_sh.j2` script'inin manuel bir çalıştırması. Migration sırasında bir şey ters giderse geri dönüş noktanız bu.

## Adım 2 — SoftHSM2 kurulumu ve anahtar üretimi

```bash
apt install -y softhsm2 opensc   # veya dnf, os'a göre
usermod -aG softhsm {{ openbao_user }}

# Token + slot oluştur
softhsm2-util --init-token --slot 0 --label "openbao" \
  --pin "<PIN>" --so-pin "<SO-PIN>"

# AES-256 anahtar üret (aes-root etiketiyle)
pkcs11-tool --module /usr/lib/softhsm/libsofthsm2.so \
  --login --pin "<PIN>" --keygen --key-type AES:32 --label "aes-root"
```

> `<PIN>` ve `<SO-PIN>` değerlerini plaintext bırakmayın — Ansible Vault'a alın (`openbao_softhsm_pin`), master-design.md §3.2'deki OpenBao KV akışına da uygun olarak ayrı saklanmalı.

## Adım 3 — PKCS#11 KMS plugin binary'sini hazırlama

```bash
git clone https://github.com/openbao/openbao-plugins
cd openbao-plugins
make kms-pkcs11
sha256sum bin/openbao-plugin-kms-pkcs11_linux_amd64_v1
```

Binary'yi `openbao_plugin_dir`'e kopyalayın (Ansible task olarak eklenmeli), sha256sum'ı `openbao_pkcs11_plugin_sha256` değişkenine yazın.

## Adım 4 — Ansible değişkenlerini tanımlama

`group_vars/all/openbao.yml` (veya ilgili dosya) içine:

```yaml
openbao_autounseal_enabled: true
openbao_plugin_dir: "/opt/openbao/plugins"
openbao_pkcs11_plugin_bin: "openbao-plugin-kms-pkcs11_linux_amd64_v1"
openbao_pkcs11_plugin_sha256: "<adım 3'teki sha256sum>"
openbao_softhsm_lib_path: "/usr/lib/softhsm/libsofthsm2.so"
openbao_softhsm_pin: "{{ vault_openbao_softhsm_pin }}"   # Ansible Vault'tan
openbao_softhsm_token_label: "openbao"
openbao_softhsm_key_label: "aes-root"
openbao_softhsm_token_dir: "/var/lib/softhsm/tokens"
openbao_softhsm_group: "softhsm"
```

Güncellenmiş `bao-config_hcl.j2` ve `bao_service.j2` bu değişkenlere göre koşullu olarak seal/plugin bloklarını ve dosya izinlerini render eder.

## Adım 5 — Config'i uygula, servisi migration modunda başlat

```bash
ansible-playbook playbooks/openbao.yml --tags config
systemctl daemon-reload
systemctl restart bao
```

OpenBao, mevcut Shamir-sealed storage ile config'deki yeni `seal "pkcs11"` bloğu arasındaki uyuşmazlığı algılayıp **migration moduna** girer.

## Adım 6 — Migration'ı tamamlama (Shamir key'lerini bir kere daha kullanacaksınız)

Elinizdeki Shamir unseal key'lerini (threshold kadarını) `-migrate` flag'iyle girin:

```bash
bao operator unseal -migrate <shamir-key-1>
bao operator unseal -migrate <shamir-key-2>
bao operator unseal -migrate <shamir-key-3>
```

Threshold'a ulaşınca OpenBao root key'i otomatik olarak yeni PKCS#11 seal altında yeniden sarar (rewrap). Bu son kez elle unseal yaptığınız an olacak.

## Adım 7 — Doğrulama

```bash
bao status
# Sealed: false, Auto-unseal: pkcs11 görünmeli
```

Sonra fiziksel/servis restart testi yapın:

```bash
systemctl restart bao
sleep 5
bao status   # Sealed: false olmalı, elle unseal GEREKMEMELİ
```

Proxmox'u yeniden başlatıp da doğrulayın — asıl senaryonuz bu.

## Adım 8 — Eski unseal script'ini kaldırma

Migration doğrulandıktan sonra, elle unseal için kullandığınız script'i (stdin/SSH akışı) devre dışı bırakın veya arşive taşıyın — artık gerekmiyor. **Shamir unseal key'lerini silmeyin** — auto-unseal sonrası bile bir felaket kurtarma senaryosunda (SoftHSM token'ı kaybedilirse) gerekebilirler; bunları `docs/tr/maintenance/disaster-recovery.md`'de tarif edilen ayrı kanalda saklamaya devam edin.

---

## Geri Alma (Rollback)

Migration sırasında bir sorun çıkarsa:

```bash
systemctl stop bao
# config.hcl'den seal/plugin bloklarını kaldır (openbao_autounseal_enabled: false)
ansible-playbook playbooks/openbao.yml --tags config
# Gerekirse adım 1'deki snapshot'tan restore et
bao operator raft snapshot restore /root/pre-autounseal-migration.snap
systemctl start bao
```

---

## §9 — Alternatif Mimariler ve Tehdit Modeli Karşılaştırması

Bu bölüm, "elle unseal etmeyeyim" ihtiyacını karşılayan farklı yaklaşımları **gerçek güvenlik farkları** açısından karşılaştırır. Homelab ölçeğinde yukarıdaki aynı-host SoftHSM2 yeterli ve makuldür — burası, ileride production benzeri bir ortama taşınırsa hangi seçeneklerin masada olduğunu göstermek için tutulmuştur.

### Seçenek A — DIY Cron Job (Shamir key'lerini birleştirip script'le unseal)

```bash
# Örnek — yapılması ÖNERİLMEZ
0 */6 * * * /usr/local/bin/auto-unseal.sh   # 3 key'i dosyadan okuyup bao operator unseal x3 çağırır
```

**Neden önerilmiyor:** Shamir'in temel tasarım ilkesi, hiçbir tek noktanın tüm anahtara aynı anda sahip olmamasıdır (threshold — ör. 5 parçadan 3'ü gerekir). Bu key'leri tek bir script'e/dosyaya koymak, o ilkeyi doğrudan ihlal eder; ayrıca kendi yazdığınız bir mekanizma (process argümanlarında anahtarın görünmesi, boot-order race condition'ları, sessiz hata durumları) OpenBao'nun resmi test edilmiş kod yolundan geçmez. Bu seçenek, §A (aynı-host SoftHSM2) ile *aynı* tehdit modeline sahiptir (disk = her şey) ama üstüne DIY kod riski ekler — bu yüzden aynı-host SoftHSM2, DIY cron'a göre her zaman daha iyi bir seçimdir.

### Seçenek B — Aynı-host SoftHSM2 (bu runbook'un varsayılanı)

Yukarıdaki adımlarda anlatılan yaklaşım. Elle unseal yükünü kaldırır, resmi plugin mimarisini kullanır, ama disk kompromisine karşı ek koruma **sağlamaz** (anahtar ve şifreli veri aynı yerde). Homelab için makul trade-off.

### Seçenek C — Transit Auto-Unseal (ayrı bir failure domain)

Proxmox'ta **ikinci, küçük bir LXC**'de sadece Transit secrets engine'i açık minimal bir OpenBao instance'ı çalıştırılır ("unseal-helper"). Ana OpenBao, unseal isteğini bu ikinci instance'a API üzerinden yapar; anahtar hiçbir zaman ana OpenBao'nun diskinde durmaz.

```
Ana OpenBao (CT 301, Raft + PKI + KV)
      │  unseal isteği (Transit API)
      ▼
Unseal-Helper OpenBao (CT 302, sadece Transit engine)
```

**Ne kazandırır:** Saldırganın ana LXC'nin diskini ele geçirmesi artık tek başına yeterli değildir — ayrıca ikinci LXC'ye de erişmesi (veya onunla ağ üzerinden konuşabilmesi) gerekir. Bu, gerçek bir "farklı failure domain" ayrımıdır.

**Maliyeti:** Bir LXC daha (kaynak + bakım), unseal-helper'ın kendisinin de bir şekilde başlaması gerekir (genelde bu ikinci, küçük instance için Shamir/elle unseal kabul edilir — çünkü o zaten hassas veri tutmaz, sadece bir Transit anahtarı tutar ve kaybı/yeniden kurulumu görece ucuzdur).

### Seçenek D — SoftHSM2'yi farklı bir Proxmox node/disk'te çalıştırma

Fiziksel olarak birden fazla Proxmox node'unuz varsa, SoftHSM2'yi ana OpenBao'dan ayrı bir node'daki LXC'ye koyup PKCS#11'i ağ üzerinden (ör. bir proxy/relay ile) sunmak. Pratikte Seçenek C'ye benzer bir izolasyon sağlar ama PKCS#11 protokolü doğrudan ağ üzerinden tasarlanmadığı için ek bir relay katmanı gerektirir — genelde Seçenek C daha temiz bir çözümdür.

### Karar Tablosu

| Seçenek | Elle unseal'i kaldırır mı? | Disk kompromisine karşı ek koruma | Ek kaynak/karmaşıklık | Önerilen kullanım |
|---|---|---|---|---|
| A — DIY cron | ✅ | ❌ | Düşük (ama risk yüksek) | **Önerilmez** |
| B — Aynı-host SoftHSM2 | ✅ | ❌ | Düşük | **Homelab (bu runbook)** |
| C — Transit Auto-Unseal | ✅ | ✅ | Orta (1 ek LXC) | Production/hassasiyet arttığında |
| D — Uzak SoftHSM2 | ✅ | ✅ | Yüksek (relay katmanı) | Çoklu Proxmox node varsa, C'ye alternatif |

