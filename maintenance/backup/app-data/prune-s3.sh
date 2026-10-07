#!/usr/bin/env bash
# prune-s3.sh — Garage S3'teki eski backup'lari retention'a gore temizler
#
# =============================================================================
# DEPRECATED — restic gecisi sonrasi EMekLIYE HAZIR
# =============================================================================
# Bu script yalnizca LEGACY flat nesneleri (tier oncesi dosyalar) temizler;
# aktif tier agacina (etcd/daily|weekly|monthly) DOKUNMAZ. Restic tabanli yeni
# mimaride kullanimi yoktur; tek seferlik legacy temizlik icin --dry-run ile
# gozden gecirip calistirabilirsiniz.
#
# BILINEN BUG: --etcd ve --openbao birlikte verilince ikisi de false olur ve
# script hicbir sey silmez (kopyalanmayacagi icin duzeltilmez — bak:
# maintenance/script-rapor-eleştiri.md).
# =============================================================================
# BAGIMSIZ CALISIR (s3cmd veya aws CLI gerektirir)
# =============================================================================
# Ne yapar:  S3'teki eski backup'lari (etcd, openbao prefix'leri)
#            retention politikasina gore temizler.
#            Her backup script'i kendi retention'ini yonettigi icin
#            bu script manuel veya toplu temizlik icindir.
# Ne zaman:  Gunluk (cron: 0 4 * * *) veya manuel
#
# Kullanim ornekleri:
#   ./prune-s3.sh                                  # Tum retention'lari uygula
#   ./prune-s3.sh --dry-run                        # Ne silinecegini goster
#   ./prune-s3.sh --etcd 14                        # Sadece etcd, 14 gun
#   ./prune-s3.sh --openbao 60                     # Sadece openbao, 60 gun
#   ./prune-s3.sh --bucket my-backups               # Ozel bucket
#   ./prune-s3.sh --creds /path/to/garage-<CT_ID>-credentials.txt  # Credential

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "${SCRIPT_DIR}/../../_common.sh"

BUCKET="backups"
DRY_RUN=false
PRUNE_ETCD=true
PRUNE_OPENBAO=true

ETCD_RETENTION=7
OPENBAO_RETENTION=30

usage() {
    echo "Kullanim: $0 [--dry-run] [--etcd <gun>] [--openbao <gun>] [--bucket <isim>] [--creds <dosya>]"
    exit 1
}

while [[ $# -gt 0 ]]; do
    case $1 in
        --dry-run)    DRY_RUN=true; shift ;;
        --etcd)       ETCD_RETENTION="$2"; PRUNE_OPENBAO=false; shift 2 ;;
        --openbao)    OPENBAO_RETENTION="$2"; PRUNE_ETCD=false; shift 2 ;;
        --bucket)     BUCKET="$2"; shift 2 ;;
        --creds)      GARAGE_CREDS="$2"; shift 2 ;;
        -h|--help)    usage ;;
        *)            usage ;;
    esac
done

S3_CMD="$(detect_s3_cmd)"
if [ -z "$S3_CMD" ]; then
    log_error "s3cmd veya aws CLI bulunamadi"
    exit 1
fi

if ! load_garage_creds; then
    exit 1
fi

S3_OPTS=""
case "$S3_CMD" in
    s3cmd) S3_OPTS="--host=$S3_ENDPOINT --host-bucket=$S3_ENDPOINT --access_key=$S3_ACCESS_KEY --secret_key=$S3_SECRET_KEY" ;;
    aws)   S3_OPTS="--endpoint-url=$S3_ENDPOINT" ;;
esac

prune_bucket() {
    local prefix="$1"
    local retention="$2"
    local label="$3"

    CUTOFF=$(date -d "$retention days ago" +%s 2>/dev/null || date -v-"${retention}"d +%s 2>/dev/null)
    if [ -z "$CUTOFF" ]; then
        log_warn "Tarih hesaplanamadi. macOS'te 'brew install coreutils' deneyin."
        return
    fi

    log_info "$label: $retention gunden eski backup'lar temizleniyor..."

    case "$S3_CMD" in
        s3cmd)
            # shellcheck disable=SC2086
            s3cmd $S3_OPTS ls "s3://${BUCKET}/${prefix}/" 2>/dev/null | while read -r line; do
                file_date=$(echo "$line" | awk '{print $1" "$2}')
                file_path=$(echo "$line" | awk '{print $NF}')
                [ -z "$file_path" ] && continue
                file_ts=$(date -d "$file_date" +%s 2>/dev/null || echo "0")
                if [ "$file_ts" -lt "$CUTOFF" ] 2>/dev/null; then
                    if [ "$DRY_RUN" = true ]; then
                        echo "  [DRY-RUN] silinecek: $file_path ($file_date)"
                    else
                        # shellcheck disable=SC2086
                        s3cmd $S3_OPTS del "$file_path" 2>/dev/null || true
                    fi
                fi
            done
            ;;
        aws)
            # shellcheck disable=SC2086
            aws s3 $S3_OPTS ls "s3://${BUCKET}/${prefix}/" 2>/dev/null | while read -r line; do
                file_date=$(echo "$line" | awk '{print $1" "$2}')
                file_name=$(echo "$line" | awk '{print $NF}')
                [ -z "$file_name" ] && continue
                file_ts=$(date -d "$file_date" +%s 2>/dev/null || echo "0")
                if [ "$file_ts" -lt "$CUTOFF" ] 2>/dev/null; then
                    if [ "$DRY_RUN" = true ]; then
                        echo "  [DRY-RUN] silinecek: s3://${BUCKET}/${prefix}/${file_name} ($file_date)"
                    else
                        # shellcheck disable=SC2086
                        aws s3 $S3_OPTS rm "s3://${BUCKET}/${prefix}/${file_name}" 2>/dev/null || true
                    fi
                fi
            done
            ;;
    esac
}

[ "$PRUNE_ETCD" = true ] && prune_bucket "etcd" "$ETCD_RETENTION" "etcd"
[ "$PRUNE_OPENBAO" = true ] && prune_bucket "openbao" "$OPENBAO_RETENTION" "OpenBao"

if [ "$DRY_RUN" = true ]; then
    log_info "[DRY-RUN] Hicbir sey silinmedi. --dry-run olmadan calistirin."
fi
log_ok "Prune tamamlandi"
