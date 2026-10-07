# OpenBao Auto-Unseal Kurulum Rehberi - PKCS#11 / SoftHSM2

Bu doküman `docs/openbao-security/openbao/server/` altında bulunan örnek Ansible dosyalarının nasıl kullanılacağını, mevcut projenize nasıl entegre edileceğini ve 2.7 uyumlu plugin-tabanlı auto-unseal akışını açıklar.

## 1. Amaç ve Kapsam

Mevcut kurulum Shamir seal kullanıyor. Bu rehberle:
* Auto-unseal `openbao_autounseal_enabled: false` default ile mevcut projeye dokunmadan eklenir.
* İsteyen kullanıcı örnek dosyaları `ansible/roles/openbao/server/` altına kopyalayarak plugin-tabanlı PKCS#11 auto-unseal'ı aktive edebilir.
* 2.7.0'da built-in PKCS11 seal'in kaldırılması nedeniyle `plugin "kms" "pkcs11"` yaklaşımı kullanılır.

## 2. Dosya Haritası

```
docs/openbao-security/
├─ openbao/
│  └─ server/
│     ├─ defaults/main.yml
│     ├─ tasks/autounseal.yml
│     └─ templates/
│        ├─ bao.service.j2
│        └─ bao-config.hcl.j2
├─ all-yml-bao-section.yml
└─ autounseal-setup-guide.md
```

## 3. Değişkenler

Örnek değişkenler `docs/openbao-security/openbao/server/defaults/main.yml` ve `all-yml-bao-section.yml` içinde.

Mevcut `ansible/inventory/group_vars/all/all.yml` içindeki `openbao:` bloğuna eklenmesi gereken yeni anahtarlar:
* `autounseal_enabled` → `false` default
* `plugin_dir`, `pkcs11_plugin_bin`, `pkcs11_plugin_sha256`
* `softhsm_lib_path`, `softhsm_pin`, `softhsm_so_pin`, `softhsm_token_label`, `softhsm_key_label`, `softhsm_token_dir`, `softhsm_group`

Not: `softhsm_pin` Ansible Vault ile saklanmalı.

## 4. Entegrasyon Adımları

1. **Değişkenleri kopyala**
   `docs/openbao-security/all-yml-bao-section.yml` içindeki `openbao:` bloğunu mevcut `ansible/inventory/group_vars/all/all.yml` dosyasına ekle. `autounseal_enabled: false` bırak.

2. **Defaults**
   `docs/openbao-security/openbao/server/defaults/main.yml` içindeki değişkenleri `ansible/roles/openbao/server/defaults/main.yml` dosyanıza ekle.

3. **Task entegrasyonu**
   `docs/openbao-security/openbao/server/tasks/autounseal.yml` dosyasını `ansible/roles/openbao/server/tasks/` altına kopyala ve `main.yml` içinde uygun noktada `include_tasks: autounseal.yml` ekle. Task `when: openbao_autounseal_enabled | bool` ile korunuyor.

4. **Şablon entegrasyonu**
   `docs/openbao-security/openbao/server/templates/bao.service.j2` ve `bao-config.hcl.j2` örnek şablonlarını mevcut şablonlarla birleştir. Koşullu bloklar `openbao_autounseal_enabled | default(false)` ile çalışır.

## 5. Migration Akışı

Auto-unseal aktif edildiğinde:
1. `bao operator raft snapshot save` ile ön backup alınır.
2. SoftHSM2 kurulur, token başlatılır, AES key üretilir.
3. PKCS#11 KMS plugin binary indirilir, sha256 doğrulanır.
4. Config ve service güncellenir, OpenBao migration moduna girer.
5. `bao operator unseal -migrate` ile Shamir key'leri bir kez girilir.
6. Restart sonrası `Sealed: false` kalıcı olur.

Detaylı adımlar `docs/openbao-security/openbao-autounseal-migration.md` içinde.

## 6. Güvenlik Notları

* SoftHSM2 yazılım HSM'dir, anahtar disk üzerinde kalır. Aynı LXC'de çalıştırıldığında disk kompromisi durumunda anahtar ve şifreli veri birlikte ele geçirilir. Homelab için operasyonel kolaylık sağlar, ek güvenlik katmanı sağlamaz.
* Gerçek izolasyon için Seçenek C: Transit Auto-Unseal ile ayrı LXC.
* Unseal key'leri ve SoftHSM PIN Ansible Vault'ta tutulmalı, git'e commit edilmemeli.

## 7. Geri Alma

`openbao_autounseal_enabled: false` yapıp playbook çalıştır, config ve service eski haline döner. Gerekirse `bao operator raft snapshot restore` ile geri yükle.

## 8. 2.7 Uyumluluğu

Bu kurulum plugin-tabanlı `plugin "kms" "pkcs11"` kullanır. OpenBao 2.7.0'da built-in PKCS11 seal kaldırılacak, bu yapı kırılmadan çalışmaya devam eder.
