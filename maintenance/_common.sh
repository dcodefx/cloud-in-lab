#!/usr/bin/env bash
# _common.sh — maintenance/ genelinde paylaşılan yardımcı fonksiyonlar
#
# backup/app-data/*.sh ve restore/*.sh tarafından source edilir.
# Bu dosya `set -euo pipefail` YAPMAZ — source eden script kendi başında
# ayarlamalıdır, aksi halde source eden script'in kendi hata politikasını
# ezmiş oluruz.

_MAINT_COMMON_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "${_MAINT_COMMON_DIR}/.." && pwd)"
# GARAGE_CREDS: sabit yol YOK (garage-300 vb. — tofu state creds'ı ile karışmasın).
# Dosyayı isteyen, load_garage_creds <dosya> ile verir ya da çağıran script'in
# --creds flag'i $GARAGE_CREDS'i set eder.
BACKUP_STATE_DIR="${_MAINT_COMMON_DIR}/.state"

# ---------------------------------------------------------------------------
# Log
# ---------------------------------------------------------------------------
log_info()  { echo "[INFO]  $*"; }
log_ok()    { echo "[OK]    $*"; }
log_warn()  { echo "[WARN]  $*" >&2; }
log_error() { echo "[HATA]  $*" >&2; }
log_sep()   { echo "==========================================="; }

# ---------------------------------------------------------------------------
# S3 istemci tespiti
# ---------------------------------------------------------------------------
detect_s3_cmd() {
    # Garage ile tutarli: once s3cmd; aws yalniz fallback (imza uyumsuz olabilir)
    local p
    if command -v s3cmd &>/dev/null; then
        echo "s3cmd"
        return 0
    fi
    for p in "${HOME}/bin/aws" /usr/local/bin/aws /usr/bin/aws; do
        if [ -x "$p" ] && "$p" --version 2>&1 | grep -q "aws-cli"; then
            case ":$PATH:" in
                *":$(dirname "$p"):"*) ;;
                *) export PATH="$(dirname "$p"):${PATH}" ;;
            esac
            echo "aws"
            return 0
        fi
    done
    if command -v aws &>/dev/null && aws --version 2>&1 | grep -q "aws-cli"; then
        echo "aws"
        return 0
    fi
    echo ""
}

# ---------------------------------------------------------------------------
# Garage credential yükleme — LEGACY düz dosya yolu (MAINT_STORAGE=restic ile
# üretimde kullanılmaz; yalnız geri dönüş/senaryo için kodda duruyor).
#
# Dosya yolu: çağıran script'in `--creds <dosya>` flag'i $GARAGE_CREDS'i set
# eder; sabit varsayılan yol YOKTUR.
#
# ÖNEMLİ: credential dosyası `source` EDİLMEZ, sadece bilinen S3_* satırları
# grep ile okunur. İki sebep:
#   1. Güvenlik: credential dosyasını rastgele shell kodu olarak çalıştırmamak.
#   2. Doğruluk: dosyada tanımlı olabilecek bir BUCKET değişkeni, çağıran
#      script'in kendi --bucket flag'ini/varsayılanını SESSİZCE ezmesin.
#      Bucket, uygulama seviyesinde her script'in kendi kararıdır; credential
#      dosyasından miras alınmaz.
# ---------------------------------------------------------------------------
load_garage_creds() {
    local cred_file="${GARAGE_CREDS:-}"
    if [ -z "$cred_file" ]; then
        log_error "credential dosyasi belirtilmedi — --creds <dosya> ile verin"
        return 1
    fi
    if [ ! -f "$cred_file" ]; then
        log_error "Garage credential dosyasi bulunamadi: $cred_file"
        return 1
    fi

    S3_ENDPOINT="$(grep -E '^S3_ENDPOINT=' "$cred_file" | tail -1 | cut -d= -f2- | tr -d '"'"'"'')"
    S3_ACCESS_KEY="$(grep -E '^S3_ACCESS_KEY=' "$cred_file" | tail -1 | cut -d= -f2- | tr -d '"'"'"'')"
    S3_SECRET_KEY="$(grep -E '^S3_SECRET_KEY=' "$cred_file" | tail -1 | cut -d= -f2- | tr -d '"'"'"'')"

    if [ -z "$S3_ENDPOINT" ] || [ -z "$S3_ACCESS_KEY" ] || [ -z "$S3_SECRET_KEY" ]; then
        log_error "Credential dosyasinda S3_ENDPOINT/S3_ACCESS_KEY/S3_SECRET_KEY eksik: $cred_file"
        return 1
    fi
    export S3_ENDPOINT S3_ACCESS_KEY S3_SECRET_KEY
    # aws CLI credential'i bayrakla almaz — env ile besle (s3cmd bayrak kullanir)
    export AWS_ACCESS_KEY_ID="$S3_ACCESS_KEY"
    export AWS_SECRET_ACCESS_KEY="$S3_SECRET_KEY"
    export AWS_DEFAULT_REGION="${AWS_DEFAULT_REGION:-us-east-1}"
    return 0
}

# S3 komut satiri için Garage HTTP endpoint'i normalize et.
# http://ip:port → s3cmd: --no-ssl --host=ip:port --host-bucket=ip:port (path-style)
# Not: %(bucket)s.host virtual-host DNS dener — Garage IP'de KULLANMA.
_s3_endpoint_host() {
    echo "${S3_ENDPOINT:-}" | sed -E 's#^https?://##'
}

_s3cmd_base() {
    local host
    host="$(_s3_endpoint_host)"
    echo --no-ssl --host="$host" --host-bucket="$host" \
        --access_key="$S3_ACCESS_KEY" --secret_key="$S3_SECRET_KEY"
}

# S3'e dosya yükler. Kullanım: s3_put <cmd> <bucket> <yerel-dosya> <s3-path>
s3_put() {
    local cmd="$1" bucket="$2" local_file="$3" s3_path="$4"
    case "$cmd" in
        s3cmd)
            # shellcheck disable=SC2046
            s3cmd $(_s3cmd_base) put "$local_file" "$s3_path"
            ;;
        aws)
            aws s3 --endpoint-url="$S3_ENDPOINT" cp "$local_file" "$s3_path"
            ;;
        *)
            log_error "Bilinmeyen S3 komutu: $cmd"
            return 1
            ;;
    esac
}

# S3'ten dosya indirir. Kullanım: s3_get <cmd> <s3-path> <yerel-hedef>
s3_get() {
    local cmd="$1" s3_path="$2" dest="$3"
    case "$cmd" in
        s3cmd)
            # shellcheck disable=SC2046
            s3cmd $(_s3cmd_base) get "$s3_path" "$dest"
            ;;
        aws)
            aws s3 --endpoint-url="$S3_ENDPOINT" cp "$s3_path" "$dest"
            ;;
        *)
            log_error "Bilinmeyen S3 komutu: $cmd"
            return 1
            ;;
    esac
}

# Bucket/prefix altındaki en son dosyayı bulur. Kullanım: s3_find_latest <cmd> <bucket> <prefix>
s3_find_latest() {
    local cmd="$1" bucket="$2" prefix="$3"
    case "$cmd" in
        s3cmd)
            # shellcheck disable=SC2046
            s3cmd $(_s3cmd_base) ls "s3://${bucket}/${prefix}/" 2>/dev/null | sort | tail -1 | awk '{print $NF}'
            ;;
        aws)
            aws s3 --endpoint-url="$S3_ENDPOINT" ls "s3://${bucket}/${prefix}/" 2>/dev/null \
                | sort | tail -1 | awk -v b="$bucket" -v p="$prefix" '{print "s3://" b "/" p "/" $NF}'
            ;;
        *)
            log_error "Bilinmeyen S3 komutu: $cmd"
            return 1
            ;;
    esac
}

# ---------------------------------------------------------------------------
# Backup freshness takibi — sessiz cron başarısızlıklarını görünür kılmak için
# ---------------------------------------------------------------------------
record_backup_success() {
    local name="$1"
    mkdir -p "$BACKUP_STATE_DIR"
    date -u +%Y-%m-%dT%H:%M:%SZ > "${BACKUP_STATE_DIR}/${name}.last-success"
}

# Kullanım: backup_age_hours <isim>  → saat cinsinden yaş, hiç yoksa boş döner
backup_age_hours() {
    local name="$1"
    local f="${BACKUP_STATE_DIR}/${name}.last-success"
    [ -f "$f" ] || { echo ""; return 1; }
    local last epoch_last epoch_now
    last=$(cat "$f")
    epoch_last=$(date -d "$last" +%s 2>/dev/null || echo 0)
    epoch_now=$(date +%s)
    echo $(( (epoch_now - epoch_last) / 3600 ))
}

# Kullanım: is_overdue <isim> <interval_hours> <tolerance_hours>
#   son successful + interval + tolerance < ise 0 (overdue), değilse 1.
#   state yoksa da 0 (hiç successful = sorun).
is_overdue() {
    local name="$1" interval_h="$2" tol_h="${3:-0}"
    local f="${BACKUP_STATE_DIR}/${name}.last-success"
    [ -f "$f" ] || return 0
    local last epoch_last epoch_now limit_s now_s
    last=$(cat "$f")
    epoch_last=$(date -d "$last" +%s 2>/dev/null) || return 0
    now_s=$(date +%s)
    limit_s=$(( epoch_last + (interval_h + tol_h) * 3600 ))
    [ "$now_s" -gt "$limit_s" ]
}

# ---------------------------------------------------------------------------
# node_exporter textfile metrikleri — Prometheus/Alertmanager zinciri
#
# Backup job'lari (ve OnFailure/alert unit'i) basari/hata durumunu bir .prom
# dosyasina yazar; node_exporter textfile collector bu dizini sunar.
#
# KURALLAR:
#   * .prom dosyalarina ASLA token/anahtar/parola yazilmaz (sadece isim+damga)
#   * Yazma hatasi backup akisini BOZMAZ (metrik gorunurlugu best-effort)
#   * Etiket adı backup_job= (job= DEGIL): Prometheus, hedefin kendi job=
#     etiketini scrape job adiyla EZER (honor_labels varsayilan false). job=
#     kullanildiginda tum backup job'lari node-exporter olarak gorunuyordu.
#     Bkz. templates/alerts/backup.yaml.j2 — kurallar backup_job ile eslesir.
#   * <job>.prom'a IKI YAZAR girer: bu fonksiyon (basari) ve alert.sh
#     (OnFailure hatasi). backup_last_status tek degerli bir alan oldugu icin
#     "son yazan kazanir" dogru semantiktir; guvenli olmasi icin KURAL su:
#     her yazar dosyanin TAMAMINI yazar, sahibi olmadigi seriyi SILMEZ.
#     Asagidaki status=0 dalinda last-success'i .state'ten geri yuklemek bu
#     kuralin bu yazar tarafi; alert.sh da ayni serileri mevcut dosyadan
#     kopyalar. Aksi halde bir seri kaybolur ve BackupOverdue no_data'ya duser.
# Kullanım: write_backup_metric <job> <status 0|1>
#   BACKUP_MAX_AGE_SECONDS env'i (rol env dosyasından) set edilmisse esik
#   metriği de yazılır — Prometheus kuralı tek ifadeyle tüm jobları kapsar.
write_backup_metric() {
    local job="$1" status="$2"
    local dir="${METRICS_DIR:-/var/lib/${MAINT_PROJECT_NAME:-tofu-lar}/backup-metrics}"
    mkdir -p "$dir" 2>/dev/null || return 0
    local tmp="${dir}/.${job}.$$" out="${dir}/${job}.prom" now
    local last_success="" f="" last=""
    now=$(date +%s)
    if [ "$status" = "1" ]; then
        last_success="$now"
    else
        # Basarisizlikta son basari damgasini state dosyasindan geri yukle.
        # Yazilmazsa backup_last_success_timestamp_seconds kaybolur ve
        # BackupOverdue sessizce no_data durumuna duser.
        f="${BACKUP_STATE_DIR}/${job}.last-success"
        if [ -f "$f" ]; then
            last=$(cat "$f" 2>/dev/null)
            [ -n "$last" ] && last_success=$(date -d "$last" +%s 2>/dev/null || echo "")
        fi
    fi
    {
        if [ -n "$last_success" ]; then
            echo "# HELP backup_last_success_timestamp_seconds Last successful backup run (unix epoch)"
            echo "# TYPE backup_last_success_timestamp_seconds gauge"
            echo "backup_last_success_timestamp_seconds{backup_job=\"${job}\"} ${last_success}"
        fi
        echo "# HELP backup_last_status Last backup status: 1=ok 0=failed"
        echo "# TYPE backup_last_status gauge"
        echo "backup_last_status{backup_job=\"${job}\"} ${status}"
        if [ -n "${BACKUP_MAX_AGE_SECONDS:-}" ]; then
            echo "# HELP backup_max_age_seconds Freshness threshold for this job (seconds)"
            echo "# TYPE backup_max_age_seconds gauge"
            echo "backup_max_age_seconds{backup_job=\"${job}\"} ${BACKUP_MAX_AGE_SECONDS}"
        fi
        if [ "$status" = "0" ]; then
            echo "# HELP backup_last_failure_timestamp_seconds Last failed backup run (unix epoch)"
            echo "# TYPE backup_last_failure_timestamp_seconds gauge"
            echo "backup_last_failure_timestamp_seconds{backup_job=\"${job}\"} ${now}"
        fi
    } > "$tmp" 2>/dev/null && mv -f "$tmp" "$out"
    return 0
}

# ---------------------------------------------------------------------------
# Restic yardımcıları — MAINT_STORAGE=restic|both modunda depolama katmanı
#
# Restic env'i iki yerden gelir:
#   1) systemd EnvironmentFile (/etc/<proj>/backup/<job>.env) → SİRSİZ ayarlar
#      (MAINT_STORAGE, JOB_NAME, KEEP_LAST, METRICS_DIR, RESTIC_REPOSITORY)
#   2) systemd credential ($CREDENTIALS_DIRECTORY/<job>-secrets) → SIRLAR
#      (RESTIC_PASSWORD_FILE, AWS_ACCESS_KEY_ID, AWS_SECRET_ACCESS_KEY)
#      systemd-creds ile AES256-GCM şifreli; açılışta çözülür, ramfs 0400.
#      Bu yüzden bu script'te parola metni hiç görünmez.
# Manuel (restore) çalıştırmada credential yok → systemd-creds_decrypt ile
# çözülür (bkz. restore/_common.sh).
# ---------------------------------------------------------------------------

# Sırları yükle: systemd service içindeyken credential'dan.
# Kullanım: load_credential  →  0 başarılı, 1 yok/yüklenemedi
load_credential() {
    [ -n "${CREDENTIAL_ENV:-}" ] || return 1
    [ -n "${CREDENTIALS_DIRECTORY:-}" ] || return 1
    local f="${CREDENTIALS_DIRECTORY}/${CREDENTIAL_ENV}"
    [ -r "$f" ] || return 1
    set -a
    # shellcheck disable=SC1090
    . "$f"
    set +a
    return 0
}

# Kullanım: restic_backup_file <tag> <dosya>  → restic backup + forget --keep-last
restic_backup_file() {
    local tag="$1" file="$2"
    local keep="${KEEP_LAST:-12}"
    if ! command -v restic &>/dev/null; then
        log_error "restic bulunamadi (PATH?) — MAINT_STORAGE=restic gerektirir"
        return 1
    fi
    if [ -z "${RESTIC_REPOSITORY:-}" ]; then
        log_error "RESTIC_REPOSITORY tanimli degil (env dosyasi: /etc/*/backup/*.env)"
        return 1
    fi
    # Sırlar (RESTIC_PASSWORD_FILE, AWS_ACCESS_KEY_ID, AWS_SECRET_ACCESS_KEY)
    # artık .env'de değil, systemd credential'ında şifreli. Burada yükleniyor ki
    # üç backup script'i de aynı fonksiyondan geçsin (DRY). Elle çalıştırmada
    # credential yoktur -> net hata ver; restic'in yaniltici "no credentials"
    # mesajini beklemektense.
    if ! load_credential; then
        log_error "Sifreli credential yuklenemedi (CREDENTIAL_ENV=${CREDENTIAL_ENV:-<yok>})"
        log_error "Bu job systemd servisi olarak calismalidir. Elle calistirmak icin:"
        log_error "  systemctl start ${MAINT_PREFIX:-tofu-lar}-backup-${JOB_NAME:-<job>}"
        return 1
    fi
    log_info "restic: yukleniyor -> ${RESTIC_REPOSITORY} (keep-last ${keep})"
    if ! restic backup --tag "$tag" "$file"; then
        log_error "restic backup basarisiz: ${file}"
        return 1
    fi
    if ! restic forget --tag "$tag" --keep-last "$keep" --prune; then
        log_error "restic forget/prune basarisiz (keep-last ${keep})"
        return 1
    fi
    log_ok "restic: $(basename "$file") yuklendi (keep-last ${keep})"
    return 0
}


# ---------------------------------------------------------------------------
# Tier (daily / weekly / monthly) — her yedek türü kendi klasör ağacında
#
#   <root>/daily/    <dosya>                      (her başarılı alım)
#   <root>/weekly/   <dosya>-weekly.<ext>        (ISO haftanın son successful'ı)
#   <root>/monthly/  <dosya>-monthly.<ext>       (ayın son successful'ı)
#
# Damga: YYYYMMDD-HHMMSS (vzdump alt çizgili damgalar kopyalanırken normalize).
# Silme: yalnız o klasörün içi; çapraz tier temizliği yok.
# Promote: ilk successful = seed; aynı dönemde tekrar → eskiyi silip yenile
#          (dönem sonunda elde kalan = son successful); yeni dönem → ekle.
# ---------------------------------------------------------------------------

# Dosya adındaki YYYYMMDD-HHMMSS damgasını bulur (vzdump _ formunu da normalize eder)
tier_stamp_from_name() {
    local n="$1" s
    s="$(echo "$n" | grep -oE '[0-9]{8}-[0-9]{6}' | head -1 || true)"
    if [ -z "$s" ]; then
        s="$(echo "$n" | sed -nE 's/.*([0-9]{4})_([0-9]{2})_([0-9]{2})-([0-9]{2})_([0-9]{2})_([0-9]{2}).*/\1\2\3-\4\5\6/p')"
    fi
    echo "$s"
}

# Damgadan ISO hafta kimliği: 20260924-143000 → 2026-W39
_tier_week_id_from_stamp() {
    date -d "${1:0:8}" +%G-W%V 2>/dev/null || true
}

# Damgadan ay kimliği: 20260924-143000 → 202609
_tier_month_id_from_stamp() {
    echo "${1:0:6}"
}

# Dönem kimliği (suffix'e göre): "" | 2026-W39 | 202609
tier_period_id() {
    local stamp="$1" suffix="$2"
    case "$suffix" in
        -weekly)  _tier_week_id_from_stamp "$stamp" ;;
        -monthly) _tier_month_id_from_stamp "$stamp" ;;
        *)        echo "" ;;
    esac
}

# Hedef dosya adı: damgayı normalize et, suffix'i uzantının önüne koy
#   etcd-20260924-143000.db + -weekly        → etcd-20260924-143000-weekly.db
#   vzdump-lxc-300-2026_09_24-03_00_00.tar.zst + -weekly
#     → vzdump-lxc-300-20260924-030000-weekly.tar.zst
tier_dest_name() {
    local base="$1" suffix="$2"
    base="$(echo "$base" | sed -E 's/([0-9]{4})_([0-9]{2})_([0-9]{2})-([0-9]{2})_([0-9]{2})_([0-9]{2})/\1\2\3-\4\5\6/')"
    if [ -z "$suffix" ]; then
        echo "$base"
        return 0
    fi
    # Cok parcalarli arsiv uzantilari once (tar.zst vb.)
    case "$base" in
        *.tar.zst) echo "${base%.tar.zst}${suffix}.tar.zst"; return 0 ;;
        *.tar.gz)  echo "${base%.tar.gz}${suffix}.tar.gz";  return 0 ;;
        *.tar.xz)  echo "${base%.tar.xz}${suffix}.tar.xz";  return 0 ;;
        *.tar)     echo "${base%.tar}${suffix}.tar";        return 0 ;;
    esac
    if [[ "$base" == *.* && "$base" != .* ]]; then
        echo "${base%.*}${suffix}.${base##*.}"
    else
        echo "${base}${suffix}"
    fi
}

# Son dosyayı bul (damgalı lexical sort = kronolojik)
_tier_latest_file() {
    local dir="$1"
    [ -d "$dir" ] || return 0
    find "$dir" -maxdepth 1 -type f 2>/dev/null | sort | tail -1
}

# Aynı dönemin eski dosyalarını sil (promote öncesi). Boş dönem = nothing.
_tier_remove_same_period() {
    local dir="$1" period="$2"
    [ -n "$period" ] || return 0
    [ -d "$dir" ] || return 0
    local f ss sp
    while IFS= read -r f; do
        [ -n "$f" ] || continue
        ss="$(tier_stamp_from_name "$(basename "$f")")"
        [ -n "$ss" ] || continue
        sp="$(tier_period_id "$ss" "$3")"
        if [ "$sp" = "$period" ]; then
            rm -f "$f"
            log_info "tier replace: $(basename "$f")"
        fi
    done < <(find "$dir" -maxdepth 1 -type f 2>/dev/null)
}

# Yerel tier yazma/promote.
# Kullanım: tier_write_local <tier_dir> <src_file> <stamp> <suffix>
#   suffix: "" (daily) | -weekly | -monthly
#   Prune çağrılmaz; çağırán tier_prune ile limit uygular.
tier_write_local() {
    local dir="$1" src="$2" stamp="$3" suffix="${4:-}"
    mkdir -p "$dir"

    local period dest
    period="$(tier_period_id "$stamp" "$suffix")"
    if [ -n "$period" ]; then
        _tier_remove_same_period "$dir" "$period" "$suffix"
    fi

    dest="$(tier_dest_name "$(basename "$src")" "$suffix")"
    cp -f "$src" "${dir}/${dest}"
    log_info "tier $(basename "$dir"): ${dest}"
    return 0
}

# Klasör içi en fazla N dosya tut, fazlasını sil.
# Kullanım: tier_prune <dir> <keep_n> [--dry-run]
tier_prune() {
    local dir="$1" keep="$2" dry="${3:-}"
    [ -d "$dir" ] || return 0
    local files=()
    while IFS= read -r line; do
        files+=("$line")
    done < <(find "$dir" -maxdepth 1 -type f 2>/dev/null | sort)

    local total=${#files[@]}
    [ "$total" -le "$keep" ] && return 0

    local excess=$(( total - keep ))
    local i
    for (( i=0; i<excess; i++ )); do
        if [ "$dry" = "--dry-run" ]; then
            log_info "[DRY-RUN] prune: $(basename "${files[i]}")"
        else
            rm -f "${files[i]}"
            log_info "prune: $(basename "${files[i]}")"
        fi
    done
    return 0
}

# ---------------------------------------------------------------------------
# S3 tier yardımcıları — prefix altında daily|weekly|monthly
#   ör: etcd → s3://bucket/etcd/daily/
# ---------------------------------------------------------------------------

# S3'ten nesne siler. Kullanım: s3_del <cmd> <bucket> <key>
s3_del() {
    local cmd="$1" bucket="$2" key="$3"
    case "$cmd" in
        s3cmd)
            # shellcheck disable=SC2046
            s3cmd $(_s3cmd_base) del "s3://${bucket}/${key}"
            ;;
        aws)
            aws s3 --endpoint-url="$S3_ENDPOINT" rm "s3://${bucket}/${key}"
            ;;
        *)
            log_error "Bilinmeyen S3 komutu: $cmd"
            return 1
            ;;
    esac
}

# Tier listesi (basename, sort'lu). Kullanım: s3_tier_list <cmd> <bucket> <tier> <prefix>
s3_tier_list() {
    local cmd="$1" bucket="$2" tier="$3" prefix="$4"
    local uri="s3://${bucket}/${prefix}/${tier}/"
    case "$cmd" in
        s3cmd)
            # shellcheck disable=SC2046
            s3cmd $(_s3cmd_base) ls "$uri" 2>/dev/null | awk '{print $NF}' | xargs -r -n1 basename | sort
            ;;
        aws)
            aws s3 --endpoint-url="$S3_ENDPOINT" ls "$uri" 2>/dev/null \
                | awk '{print $NF}' | xargs -r -n1 basename | sort
            ;;
        *) return 1 ;;
    esac
}

# S3 tier promote/seed: aynı dönemin eski nesnesini siler, yenisini yazar.
# Kullanım: s3_tier_promote <cmd> <bucket> <tier> <prefix> <local> <stamp>
#   daily çağrılırken suffix'siz s3_put yeterli; bu fonksiyon weekly/monthly için.
s3_tier_promote() {
    local cmd="$1" bucket="$2" tier="$3" prefix="$4" src="$5" stamp="$6"
    local suffix period
    case "$tier" in
        weekly)  suffix="-weekly" ;;
        monthly) suffix="-monthly" ;;
        *)
            log_error "s3_tier_promote: tier weekly|monthly olmalı (gelen: $tier)"
            return 1
            ;;
    esac
    period="$(tier_period_id "$stamp" "$suffix")"
    [ -n "$period" ] || { log_error "tier period hesaplanamadı: stamp=$stamp"; return 1; }

    # Aynı dönemin eski nesnelerini sil
    local names name ss sp
    names="$(s3_tier_list "$cmd" "$bucket" "$tier" "$prefix")"
    while IFS= read -r name; do
        [ -n "$name" ] || continue
        ss="$(tier_stamp_from_name "$name")"
        [ -n "$ss" ] || continue
        sp="$(tier_period_id "$ss" "$suffix")"
        if [ "$sp" = "$period" ]; then
            if ! s3_del "$cmd" "$bucket" "${prefix}/${tier}/${name}"; then
                log_warn "eski tier nesnesi silinemedi: ${prefix}/${tier}/${name}"
            else
                log_info "tier replace: ${prefix}/${tier}/${name}"
            fi
        fi
    done <<< "$names"

    local obj
    obj="$(tier_dest_name "$(basename "$src")" "$suffix")"
    if ! s3_put "$cmd" "$bucket" "$src" "s3://${bucket}/${prefix}/${tier}/${obj}"; then
        log_error "tier yükleme başarısız: ${prefix}/${tier}/${obj}"
        return 1
    fi
    log_info "tier ${tier}: ${obj}"
    return 0
}

# S3 tier prune: en fazla keep nesne, fazlasını sil (en eski önce).
# Kullanım: s3_tier_prune <cmd> <bucket> <tier> <prefix> <keep> [--dry-run]
s3_tier_prune() {
    local cmd="$1" bucket="$2" tier="$3" prefix="$4" keep="$5" dry="${6:-}"
    local names
    names="$(s3_tier_list "$cmd" "$bucket" "$tier" "$prefix")"
    [ -z "$names" ] && return 0

    local arr=()
    while IFS= read -r line; do
        [ -n "$line" ] && arr+=("$line")
    done <<< "$names"

    local total=${#arr[@]}
    [ "$total" -le "$keep" ] && return 0

    local excess=$(( total - keep ))
    local i
    for (( i=0; i<excess; i++ )); do
        local key="${prefix}/${tier}/${arr[i]}"
        if [ "$dry" = "--dry-run" ]; then
            log_info "[DRY-RUN] s3 prune: $key"
            continue
        fi
        if s3_del "$cmd" "$bucket" "$key"; then
            log_info "s3 prune: $key"
        else
            log_warn "s3 prune başarısız: $key"
        fi
    done
    return 0
}

# ---------------------------------------------------------------------------
# Arşiv bütünlük kontrolü — restore'dan önce, yıkıcı işleme geçmeden önce
#
# FAIL-CLOSED: doğrulama yapılamıyorsa 0 dönmek, çağıranı "arşiv sağlam" sanar
# ve `pct destroy` sonrası bozuk arşivle `pct restore` denemesine yol açar —
# yani çalışan instance kaybolur, restore da başarısız olur. Bu yüzden her
# yol 0 döndüğünde zstd gerçekten frame'ı doğrulamış olmalıdır.
#
# `tar -I zstd` fallback'i bilerek YOK: `-I` zstd BINARY'sini çalıştırır, yani
# ancak zstd kuruluysa çalışır. Eskiden `command -v tar` diye korunup aslında
# ölü bir dal oluşuyordu; zstd yoksa o dal da hata verip çağıranı "arşiv bozuk"
# diye yanlış teşhis ediyordu. Artık tek yol var ve o da açıkça hata verir.
# ---------------------------------------------------------------------------
verify_zst_archive() {
    local file="$1"
    if command -v zstd >/dev/null 2>&1; then
        zstd -t "$file" >/dev/null 2>&1
        return $?
    fi
    log_error "zstd bulunamadi: arşiv bütünlüğü doğrulanamaz: $file"
    log_error "pve-manager zstd bagimliligini getirir; kurulu degilse ya da PATH'te"
    log_error "görünmüyorsa arşiv geri yuklenemez. DOGRULAMA YAPILAMADIGI ICIN DEVAM EDILEMIYOR."
    return 1
}
