#!/usr/bin/env bash
# _common.sh — restore/ script'lerine özel yardımcı fonksiyonlar
#
# Paylaşılan log/S3/backup-freshness fonksiyonları için ../_common.sh'ı
# source eder; burada sadece restore/VM'e özel fonksiyonlar tutulur.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "${SCRIPT_DIR}/../_common.sh"

RESTORE_BACKUP_DIR="/var/lib/vz/dump"
TEMP_DIR="/tmp/restore-work"

# Root kontrolu
check_root() {
    if [ "$(id -u)" -ne 0 ]; then
        log_error "Bu script root yetkisi gerektirir."
        exit 1
    fi
}

# Yikici komutun stderr ciktisini ekrana bas (dosyaya yonlendirildiyse).
# Onceki surum `2>/dev/null` ile stderr'i tamamen yok ediyordu: pct restore,
# qmrestore ve etcdctl snapshot restore BASARISIZ oldugunda operator yalnizca
# "Restore basarisiz" goruyor, hatanin NEDENINI gormuyordu. Hata ayiklama
# tam da en pahali anda imkansiz hale geliyordu.
#
# Kullanim: show_command_error <log_dosyasi> [gosterilecek_satir]
show_command_error() {
    local log_file="$1" lines="${2:-15}"
    [ -s "$log_file" ] || return 0
    log_error "Komut ciktisi (son ${lines} satir, tamam: ${log_file}):"
    tail -n "$lines" "$log_file" | while IFS= read -r line || [ -n "$line" ]; do
        log_error "    ${line}"
    done
}

# En son vzdump backup'ini bul — tier (weekly/monthly) once, flat fallback.
# Kullanim: find_latest_backup <pattern>
# Karsilastirma tam path sort'u DEGIL, dosya adindaki YYYYMMDD-HHMMSS damgasi
# uzerinden yapilir (tier/... altindaki monthly/weekly alfabetik path kiyasi
# weekly'yi haksiz kazanirdirdi — bak: script-rapor-eleştiri.md).
find_latest_backup() {
    local pattern="$1"
    local -a cands=()
    local f s best="" best_stamp=""

    if [ -d "${RESTORE_BACKUP_DIR}/tier" ]; then
        while IFS= read -r f; do cands+=("$f"); done \
            < <(find "${RESTORE_BACKUP_DIR}/tier" -name "$pattern" -type f 2>/dev/null)
    fi
    while IFS= read -r f; do cands+=("$f"); done \
        < <(find "$RESTORE_BACKUP_DIR" -maxdepth 1 -name "$pattern" -type f 2>/dev/null)

    for f in "${cands[@]}"; do
        [ -n "$f" ] || continue
        s="$(tier_stamp_from_name "$(basename "$f")")"
        [ -n "$s" ] || continue
        if [ -z "$best_stamp" ] || [[ "$s" > "$best_stamp" ]]; then
            best="$f"; best_stamp="$s"
        fi
    done
    echo "$best"
}

# Garage'dan dosya indir. Kullanım: download_from_garage <s3-path> <hedef>
download_from_garage() {
    local s3_path="$1" dest="$2"
    if ! load_garage_creds; then return 1; fi
    local cmd
    cmd=$(detect_s3_cmd)
    [ -z "$cmd" ] && { log_error "s3cmd veya aws CLI bulunamadi"; return 1; }
    s3_get "$cmd" "$s3_path" "$dest"
}

# Garage'daki en son snapshot'i bul (tier: daily/weekly/monthly + flat legacy fallback).
# Kullanim: find_garage_latest <prefix>
#   prefix ör: etcd → etcd/daily/, etcd/weekly/, etcd/monthly/, sonra düz etcd/
#   Siralama dosya adindaki damgaya gore (lexical) — en yeni doner.
find_garage_latest() {
    local prefix="$1" bucket="${BUCKET:-backups}"
    if ! load_garage_creds; then return 1; fi
    local cmd
    cmd=$(detect_s3_cmd)
    [ -z "$cmd" ] && { log_error "s3cmd veya aws CLI bulunamadi"; return 1; }

    local best="" best_name=""
    local p entry name
    for p in "${prefix}/daily" "${prefix}/weekly" "${prefix}/monthly" "$prefix"; do
        entry="$(s3_find_latest "$cmd" "$bucket" "$p" || true)"
        [ -n "$entry" ] || continue
        name="$(basename "$entry")"
        if [ -z "$best_name" ] || [[ "$name" > "$best_name" ]]; then
            best="$entry"
            best_name="$name"
        fi
    done
    echo "$best"
}

# ---------------------------------------------------------------------------
# Şifreli credential çözme — restore için.
#
# Servis içinde systemd credential'ı $CREDENTIALS_DIRECTORY'ye koyar; ama
# restore MANUEL çalışır (insan konsoldan) → credential yok. Aynı şifreli
# dosyayı systemd-creds ile çözüp ortama yüklüyoruz.
#
# Kullanım: systemd-creds_decrypt <job>  → 0 başarılı, 1 yok/çözülemedi
# NOT: systemd ≥250 gerekir (LoadCredentialEncrypted). host key
# /var/lib/systemd/credential.secret'te durur → root şart.
systemd-creds_decrypt() {
    local job="$1"
    local conf="${CONF_DIR:-/etc/${MAINT_PROJECT_NAME:-tofu-lar}}/backup/${job}.secrets.conf"
    if [ ! -f "$conf" ]; then
        log_error "Sifreli credential bulunamadi: ${conf}"
        log_info "Uretmek icin: ansible-playbook playbooks/maintenance.yml"
        return 1
    fi
    if ! command -v systemd-creds &>/dev/null; then
        log_error "systemd-creds yok (systemd < 250?) — credential cozulemez"
        return 1
    fi
    local out
    # --name zorunlu: dosya adı "<job>.secrets.conf", gömülü ad
    # "<job>-secrets" — systemd-creds bu ikisini karşılaştırıp reddeder.
    # encrypt tarafı: ansible/roles/maintenance/tasks/encrypt-creds.yml
    if ! out="$(systemd-creds decrypt --name="${job}-secrets" "$conf")"; then
        log_error "systemd-creds decrypt basarisiz: ${conf}"
        log_info "Host key degismis olabilir (yeniden kurulum) → playbook'i tekrar calistir"
        return 1
    fi
    set -a
    # shellcheck disable=SC1090
    . /dev/stdin <<< "$out"
    set +a
    return 0
}

# ---------------------------------------------------------------------------
# OpenBao durumunu socket üzerinden sor, yalnız exit code döndür.
#
# rc: 0 = unsealed, 2 = sealed, 1 = erişilemez/hata.
# Kullanım: bao_status_rc || rc=$?   (set -e yüzünden hep bu biçimde çağır)
#
# İki çağrı noktası var (restore-openbao.sh): pre-flight kontrolü ve raft
# restore sonrası doğrulama döngüsü. Tek yerde toplanmasının sebebi, "node
# ayakta mı" sorusunun tek ve aynı tanımla cevaplanması — iki farklı yorum
# felaket anında farklı karara yol açar.
# ---------------------------------------------------------------------------
bao_status_rc() {
    BAO_ADDR="unix://${BAO_AGENT_SOCK:-/etc/bao/agent.sock}" bao status >/dev/null 2>&1
}

# ---------------------------------------------------------------------------
# Restic kaynak seçimi — restic repodan verilen snapshot (veya latest) dosyasini indirir.
#
# Kullanım: restic_fetch_latest <env_file> <dest> [snapshot_ref]
#   env_file: rolün dağıttığı backup env dosyası (/etc/<project>/backup/<job>.env)
#   snapshot_ref: snapshot ID veya 'latest' (varsayılan: latest)
#   Başarısızsa 1 döner — çağıran legacy Garage yoluna düşebilir.
# ---------------------------------------------------------------------------
restic_fetch_latest() {
    local env_file="$1" dest="$2" snap_ref="${3:-latest}"
    [ -f "$env_file" ] || return 1

    # yalnız bilinen KEY=VALUE satırlarını al, sonra export et
    set -a
    # shellcheck disable=SC1090
    . "$env_file"
    set +a

    # Sırlar .env'de değil; job adı dosya adından türetilir
    # (/etc/<proj>/backup/openbao-daily.env -> openbao-daily).
    local job
    job="$(basename "$env_file" .env)"
    if ! systemd-creds_decrypt "$job"; then
        return 1
    fi

    command -v restic &>/dev/null || { log_error "restic bulunamadi"; return 1; }
    [ -n "${RESTIC_REPOSITORY:-}" ] || { log_error "env'de RESTIC_REPOSITORY yok: $env_file"; return 1; }

    local path
    path="$(restic ls "$snap_ref" 2>/dev/null | awk '{print $NF}' | grep -E '\.(db|snap)$' | tail -1 || true)"
    [ -n "$path" ] || { log_error "restic ${snap_ref} içinde uygun dosya yok"; return 1; }

    log_info "restic: ${RESTIC_REPOSITORY} (${snap_ref}) → $(basename "$path") indiriliyor..."
    if ! restic dump "$snap_ref" "$path" > "$dest"; then
        log_error "restic dump basarisiz: $path (ref: $snap_ref)"
        return 1
    fi
    return 0
}

# etcd snapshot dogrulama — etcd 3.5+ 'snapshot status' etcdutl'e tasindi,
# etcdctl 3.6'da kaldirildi. Once etcdutl, yoksa etcdctl, o da degilse boyut.
# Kullanım: verify_etcd_snapshot <file>  → 0 gecerli, 1 gecersiz
verify_etcd_snapshot() {
    local f="$1"
    if command -v etcdutl &>/dev/null; then
        etcdutl snapshot status "$f" 2>/dev/null | grep -q "revision" && return 0
        return 1
    fi
    if ETCDCTL_API=3 etcdctl snapshot status "$f" 2>/dev/null | grep -q "revision"; then
        return 0
    fi
    # fallback: etcdutl yok VE etcdctl 3.6+ — boyut heuristigi
    local bytes
    bytes=$(stat -c%s "$f" 2>/dev/null || echo 0)
    [ "$bytes" -ge 1048576 ] && return 0
    return 1
}

# raft snapshot dogrulama — SIFIRSAL KONTROL, CIKIRDISI DOGRULAMA
#
# OpenBao OSS'te resmi "snapshot status/inspect" komutu YOK (operator raft
# altinda yalnizca save + restore vardir; list/inspect Vault Enterprise'a
# ozel). Onceki surum bu yuzden yalniz boyut + NUL bayt kontrol ediyordu —
# 1 baytlik HTML hata ciktisi 1024 esigini gecer ve yuklemeye gider.
#
# Snapshot'in ARSIV FORMATI ise kaynak kodda acik:
#   internal/physical/raft/snapshot/archive.go
#     gzip( tar( meta.json      raft metadata
#                state.bin      raft verisi
#                SHA256SUMS     yukaridaki iki dosyanin SHA-256 toplamlari
#                SHA256SUMS.sealed ) )
#
# Yani OpenBao'ya baglanmadan, hatta icerigi "anlamadan" kriptografik
# dogrulama mumkun:
#     gzip -dc f | tar -x -C <tmp> && (cd <tmp> && sha256sum -c SHA256SUMS)
#
# Onay ilkesi (PRENSIPLER #19 fail-fast, #0 dogrulama): arac yoksa "gecmis"
# degil "bilinmiyor" sayilir. Bozuk ya da yarim kalmis snapshot gecerli
# sayilmaz.
#
# Kullanim: verify_raft_snapshot <file>  → 0 gecerli, 1 gecersiz/bilinmiyor
verify_raft_snapshot() {
    local f="$1" bytes
    [ -f "$f" ] || { log_error "Snapshot dosyasi yok: $f"; return 1; }

    bytes=$(stat -c%s "$f" 2>/dev/null || stat -f%z "$f" 2>/dev/null || echo 0)
    if [ "$bytes" -lt 1024 ]; then
        log_error "Raft snapshot suphe uyandirici kucuk (${bytes} bayt) — yukleme iptal"
        return 1
    fi

    # Arac kontrolu: olcmeyi yapacak bosta hicbir sey olmamali.
    local missing="" tool
    for tool in gzip tar sha256sum; do
        command -v "$tool" &>/dev/null || missing="${missing}${missing:+, }${tool}"
    done
    if [ -n "$missing" ]; then
        log_error "Arsiv dogrulama araclari eksik: ${missing}"
        log_error "Arac yokken 'gecerli' demek yanilticidir; yukleme iptal edildi."
        return 1
    fi

    local tmp
    tmp="$(mktemp -d)" || { log_error "Gecici dizin olusturulamadi"; return 1; }

    local rc=0 sums_entries
    if ! gzip -dc "$f" | tar -x -C "$tmp" 2>/dev/null; then
        log_error "Snapshot acilamadi (gzip/tar) — dosya bozuk ya da OpenBao snapshot'i degil"
        log_error "En olasi neden: OpenBao API'si hata ciktisi donmus (HTML/JSON metni)."
        rc=1
    elif [ ! -f "${tmp}/SHA256SUMS" ]; then
        log_error "Snapshot icinde SHA256SUMS yok — beklenen arsiv yapisinda degil"
        rc=1
    elif [ ! -f "${tmp}/meta.json" ] || [ ! -f "${tmp}/state.bin" ]; then
        log_error "Snapshot icinde meta.json veya state.bin eksik — yarim/basarisiz"
        rc=1
    else
        # Verdict yalniz EXIT CODE'e bakarak verilir. sha256sum -c "OK" /
        # "FAILED" metni YERELLE degisir (LC_ALL=tr_TR'de "OK" yerine
        # "Tamam" yazar) — cikti metnine grep/lemek sistem dili degistiginde
        # sessizce gecerli snapshot'i reddederdi.
        sums_entries="$(grep -c '[^[:space:]]' "${tmp}/SHA256SUMS" || true)"
        if [ "$sums_entries" -lt 2 ]; then
            # Bos/tek girdili SHA256SUMS'ta sha256sum -c de rc=0 verir.
            log_error "SHA256SUMS yalniz ${sums_entries} girdi iceriyor (en az 2 olmali: meta.json + state.bin)"
            rc=1
        elif ! ( cd "$tmp" && sha256sum -c SHA256SUMS >/dev/null 2>&1 ); then
            log_error "SHA256SUMS dogrulamasi BASARISIZ — snapshot bozuk:"
            # ayrinti yalniz hata halinde, sabit yerelde uretilir
            ( cd "$tmp" && LC_ALL=C sha256sum -c SHA256SUMS 2>&1 ) \
                | grep -v ': OK$' \
                | awk 'NR<=5' \
                | while IFS= read -r line; do
                log_error "    ${line}"
            done
            rc=1
        fi
    fi

    rm -rf "$tmp"
    [ "$rc" -eq 0 ] || return 1

    log_ok "Raft snapshot gecerli (${bytes} bayt, SHA256SUMS dogrulandi)"
    return 0
}

# VM/LXC tipini canli envanterden tespit et; yoksa bos string doner
detect_vm_type() {
    local vmid="$1"
    if pct list 2>/dev/null | awk 'NR>1{print $1}' | grep -qx "$vmid"; then
        echo "lxc"
    elif qm list 2>/dev/null | awk 'NR>1{print $1}' | grep -qx "$vmid"; then
        echo "vm"
    else
        echo ""
    fi
}

# VM/LXC tipini vzdump ARSIV ADINDAN turet (canli envantere bakmadan).
#
# Neden gerekli: restore'un varlik nedeni guest'in kaybolmus olmasidir.
# Onceki surum tipi yalnizca `pct list`/`qm list` ile buluyordu; envanterde
# guest yoksa (yani restore'un tam da hedefledigi durumda) tip bulunamayip
# script daha snapshot'a dokunmadan hata veriyordu. Oysa tip arsivin adinda
# yazilidir: vzdump-lxc-<vmid>-<tarih>... | vzdump-qemu-<vmid>-<tarih>...
#
# Onemli: desen "<vmid>-" sonu ile bitirilir. "vzdump-lxc-30*" deseni
# 300/301 numarali misafirlerin arsivini de eslestirir ve felaket aninda
# yanlis konuga restore yapilmasina yol acar.
#
# Kullanim: detect_vm_type_from_archive <vmid>  → "lxc"|"vm" (0), yoksa 1
detect_vm_type_from_archive() {
    local vmid="$1" type
    for type in lxc vm; do
        [ -n "$(find_latest_backup "vzdump-${type}-${vmid}-*.tar.zst")" ] || continue
        echo "$type"
        return 0
    done
    return 1
}

# VMID'ye gore ozel mesaj (kendi kurulumunuza gore genisletebilirsiniz)
vm_post_msg() {
    local vmid="$1"
    local type
    type="$(detect_vm_type "$vmid" 2>/dev/null || true)"
    if [ "$type" = "lxc" ]; then
        echo "Durum kontrolu: pct status $vmid"
    elif [ "$type" = "vm" ]; then
        echo "Durum kontrolu: qm status $vmid"
    else
        echo ""
    fi
}

# VMID'ye gore isim (Proxmox envanterinden dinamik ad, fallback: VM/LXC <vmid>)
vm_name() {
    local vmid="$1" name=""
    name="$(pct config "$vmid" 2>/dev/null | awk -F': ' '/^hostname:/{print $2}' || true)"
    if [ -z "$name" ]; then
        name="$(qm config "$vmid" 2>/dev/null | awk -F': ' '/^name:/{print $2}' || true)"
    fi
    if [ -n "$name" ]; then
        echo "$name ($vmid)"
    else
        echo "VM/LXC $vmid"
    fi
}

# ---------------------------------------------------------------------------
# kubeadm static-pod doğrulaması — VARSAYMA, TESPİT ET.
#
# Proje pure kubeadm kullanıyor: etcd/apiserver/controller-manager/scheduler
# systemd unit'i DEĞİL, kubelet'in yönettiği static pod'lardır. Bu fonksiyon
# o varsayımı körü körüne kabul etmek yerine gerçekten doğrular; beklenmeyen
# bir durum varsa (manifest yok, kubelet çalışmıyor) restore script'i devam
# etmek yerine AÇIKÇA durur — sessizce yanlış bir yola sapmaz.
# ---------------------------------------------------------------------------
KUBE_MANIFEST_DIR="/etc/kubernetes/manifests"
KUBE_MANIFEST_STAGING="/etc/kubernetes/manifests-disabled"

assert_kubeadm_static_pods() {
    if ! systemctl is-active --quiet kubelet 2>/dev/null; then
        log_error "kubelet aktif değil. Static pod tabanlı kontrol düzlemi yönetilemez."
        return 1
    fi
    for comp in etcd kube-apiserver kube-controller-manager kube-scheduler; do
        if [ ! -f "${KUBE_MANIFEST_DIR}/${comp}.yaml" ]; then
            log_error "${KUBE_MANIFEST_DIR}/${comp}.yaml bulunamadı — beklenen pure-kubeadm stacked-etcd düzeni değil."
            log_error "Bu ortam varsayılandan farklı yapılandırılmış olabilir; restore-etcd.sh güncellenmeden devam etmeyin."
            return 1
        fi
    done
    return 0
}

# Static pod'ları durdurur: manifestleri staging dizinine taşır, kubelet'in
# pod'ları gerçekten sonlandırdığını (etcd portu kapanana kadar) bekler.
stop_control_plane_static_pods() {
    mkdir -p "$KUBE_MANIFEST_STAGING"
    log_info "Kontrol düzlemi manifestleri devre dışı bırakılıyor (kubelet pod'ları durduracak)..."
    for comp in etcd kube-apiserver kube-controller-manager kube-scheduler; do
        mv "${KUBE_MANIFEST_DIR}/${comp}.yaml" "${KUBE_MANIFEST_STAGING}/${comp}.yaml"
    done

    log_info "etcd'nin gerçekten durduğu doğrulanıyor (port 2379)..."

    # Bu kontrol "etcd gercekten durdu" varsayiminin TEK kaniti. Olcum
    # yapilamiyorsa "durdu" varsaymak, calisan etcd'nin uzerine yazmaya
    # yol acar (felaket restore'unu bozan sessiz hata). Bu yuzden arac
    # yoksa ya da hata verirse restore devam etmez.
    if ! command -v ss &>/dev/null; then
        log_error "ss bulunamadi (iproute2 paketi) — etcd'nin durduğu OLCULEMEZ."
        log_error "Olcum olmadan 'durdu' denemez; restore iptal edildi."
        log_info "Kurulum: apt-get install -y iproute2"
        log_warn "Kontrol duzlemi manifestleri zaten devre disi birakildi; geri almak icin:"
        log_info "  ${KUBE_MANIFEST_STAGING}/*  ->  ${KUBE_MANIFEST_DIR}/"
        return 1
    fi

    local waited=0 ss_out
    while :; do
        if ! ss_out="$(ss -ltn 2>&1)"; then
            log_error "ss calistirilamadi — etcd'nin durduğu olculemiyor: ${ss_out}"
            log_error "Olcum olmadan 'durdu' denemez; restore iptal edildi."
            return 1
        fi
        # ":2379 " yerine ":2379[[:space:]]" — :23790 / :23799 ile eslesmesin.
        if ! printf '%s\n' "$ss_out" | grep -q ':2379[[:space:]]'; then
            break
        fi
        sleep 2
        waited=$((waited + 2))
        if [ "$waited" -ge 60 ]; then
            log_error "etcd 60 saniye sonra hâlâ dinliyor — kubelet pod'u durdurmadı, elle kontrol edin."
            return 1
        fi
    done
    log_ok "Kontrol düzlemi durduruldu (${waited}s)"
}

# Static pod manifestlerini geri koyar, kubelet'in pod'ları tekrar
# başlattığını (etcd health) doğrular.
start_control_plane_static_pods() {
    log_info "Kontrol düzlemi manifestleri geri yükleniyor (kubelet pod'ları başlatacak)..."
    for comp in etcd kube-apiserver kube-controller-manager kube-scheduler; do
        if [ -f "${KUBE_MANIFEST_STAGING}/${comp}.yaml" ]; then
            mv "${KUBE_MANIFEST_STAGING}/${comp}.yaml" "${KUBE_MANIFEST_DIR}/${comp}.yaml"
        fi
    done

    log_info "etcd'nin ayağa kalktığı doğrulanıyor..."
    local waited=0
    until etcdctl --endpoints=https://127.0.0.1:2379 \
        --cacert=/etc/kubernetes/pki/etcd/ca.crt \
        --cert=/etc/kubernetes/pki/etcd/server.crt \
        --key=/etc/kubernetes/pki/etcd/server.key \
        endpoint health 2>/dev/null | grep -q "healthy"; do
        sleep 3
        waited=$((waited + 3))
        if [ "$waited" -ge 90 ]; then
            log_error "etcd 90 saniye sonra hâlâ sağlıklı değil — elle kontrol edin: kubectl -n kube-system get pods"
            return 1
        fi
    done
    log_ok "Kontrol düzlemi sağlıklı (${waited}s içinde ayağa kalktı)"
}
