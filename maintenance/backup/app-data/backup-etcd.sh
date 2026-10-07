#!/usr/bin/env bash
# backup-etcd.sh — etcd snapshot alir; depolama katmanina yukler
#
# =============================================================================
# K8S MASTER UZERINDE CALISIR (etcdctl gerektirir)
# =============================================================================
#
# Depolama modu (MAINT_STORAGE env'i — systemd EnvironmentFile'indan gelir):
#   restic  → restic repoya yukler (sifrele+dedup+keep-last N) — YENI mimari
#   s3tier  → Garage S3 tier agacina yukler (daily/weekly/monthly) — LEGACY
#   both    → ikisi birden (shadow gecis donemi)
# Varsayilan: s3tier (elle/cron kullanimi geriye uyumlu).
#
# Retansiyon: restic → KEEP_LAST (env); s3tier → daily 12 / weekly 3 / monthly 3
# .state kaydi: JOB_NAME env'i (rol: etcd-daily|etcd-weekly|etcd-monthly)
# Geri yukleme: restore/restore-etcd.sh
#
# Kullanim ornekleri:
#   ./backup-etcd.sh                                    # Varsayilan
#   ./backup-etcd.sh --creds /path/to/credentials.txt   # Ozel credential
#   ./backup-etcd.sh --bucket my-backups                # Ozel bucket
#   ./backup-etcd.sh --dry-run                          # Sadece goster

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "${SCRIPT_DIR}/../../_common.sh"

BUCKET="backups"
DRY_RUN=false
KEEP_DAILY=12
KEEP_WEEKLY=3
KEEP_MONTHLY=3
MAINT_STORAGE="${MAINT_STORAGE:-s3tier}"
JOB_NAME="${JOB_NAME:-etcd}"

usage() {
    echo "Kullanim: $0 [--creds <dosya>] [--bucket <isim>] [--dry-run]"
    exit 1
}

while [[ $# -gt 0 ]]; do
    case $1 in
        --creds)     GARAGE_CREDS="$2"; shift 2 ;;
        --bucket)    BUCKET="$2"; shift 2 ;;
        --retention) log_warn "--retention kaldirildi; tier prune kullanilir (daily=$KEEP_DAILY weekly=$KEEP_WEEKLY monthly=$KEEP_MONTHLY)"; shift 2 ;;
        --dry-run)   DRY_RUN=true; shift ;;
        -h|--help)   usage ;;
        *)           usage ;;
    esac
done

# dry-run: bagimlilik (etcdctl/s3/health) kontrolunden ONCE plan gosterip cik
if [ "$DRY_RUN" = true ]; then
    TIMESTAMP=$(date +%Y%m%d-%H%M%S)
    log_info "[DRY-RUN] etcd snapshot alinacak -> /tmp/etcd-backup/etcd-${TIMESTAMP}.db"
    case "$MAINT_STORAGE" in
        restic)
            echo "  restic: \${RESTIC_REPOSITORY} (keep-last ${KEEP_LAST:-12})" ;;
        s3tier)
            echo "  Yuklenecek: s3://${BUCKET}/etcd/daily/etcd-${TIMESTAMP}.db"
            echo "  Tier prune: daily=$KEEP_DAILY weekly=$KEEP_WEEKLY monthly=$KEEP_MONTHLY" ;;
        both)
            echo "  restic: \${RESTIC_REPOSITORY} (keep-last ${KEEP_LAST:-12})"
            echo "  Yuklenecek: s3://${BUCKET}/etcd/daily/etcd-${TIMESTAMP}.db" ;;
    esac
    echo "  Not: gerçek snapshot K8s Master uzerinde (etcdctl) calisir."
    exit 0
fi

if ! command -v etcdctl &>/dev/null && [ ! -x "${HOME}/bin/etcdctl" ]; then
    log_error "etcdctl bulunamadi. K8s Master uzerinde calistirin."
    exit 1
fi
ETCDCTL_BIN="$(command -v etcdctl 2>/dev/null || true)"
[ -z "$ETCDCTL_BIN" ] && ETCDCTL_BIN="${HOME}/bin/etcdctl"

# server.key root'a ait; ubuntu (sudo -n) ile calisirken etcdctl'u yetki ile kos
ETCDCTL="$ETCDCTL_BIN"
if [ ! -r /etc/kubernetes/pki/etcd/server.key ] && command -v sudo &>/dev/null && sudo -n true 2>/dev/null; then
    ETCDCTL="sudo -n ${ETCDCTL_BIN}"
fi

case "$MAINT_STORAGE" in
    s3tier|both)
        S3_CMD="$(detect_s3_cmd)"
        if [ -z "$S3_CMD" ]; then
            if [ -x "${HOME}/bin/aws" ]; then
                S3_CMD="aws"
                export PATH="${HOME}/bin:${PATH}"
            else
                log_error "s3cmd veya aws CLI bulunamadi. Birini kurun: apt install s3cmd"
                exit 1
            fi
        fi

        if ! load_garage_creds; then
            exit 1
        fi
        ;;
esac

# etcd health kontrol
log_info "etcd health kontrol ediliyor..."
if ! $ETCDCTL --endpoints=https://127.0.0.1:2379 \
    --cacert=/etc/kubernetes/pki/etcd/ca.crt \
    --cert=/etc/kubernetes/pki/etcd/server.crt \
    --key=/etc/kubernetes/pki/etcd/server.key \
    endpoint health 2>/dev/null | grep -q "healthy"; then
    log_error "etcd saglikli degil. Backup alinmayacak."
    exit 1
fi
log_ok "etcd saglikli"

BACKUP_DIR="/tmp/etcd-backup"
mkdir -p "$BACKUP_DIR"
TIMESTAMP=$(date +%Y%m%d-%H%M%S)
SNAPSHOT_FILE="${BACKUP_DIR}/etcd-${TIMESTAMP}.db"

log_info "etcd snapshot aliniyor: $SNAPSHOT_FILE"
if ! ETCDCTL_API=3 $ETCDCTL --endpoints=https://127.0.0.1:2379 \
    --cacert=/etc/kubernetes/pki/etcd/ca.crt \
    --cert=/etc/kubernetes/pki/etcd/server.crt \
    --key=/etc/kubernetes/pki/etcd/server.key \
    snapshot save "$SNAPSHOT_FILE" 2>/dev/null; then
    log_error "etcd snapshot basarisiz"
    rm -f "$SNAPSHOT_FILE" 2>/dev/null || sudo -n rm -f "$SNAPSHOT_FILE" || true
    exit 1
fi

# sudo ile yazildiysa dosya sahibini geri al (aws/s3cmd ubuntu ile okumali)
if [ ! -r "$SNAPSHOT_FILE" ] && command -v sudo &>/dev/null && sudo -n true 2>/dev/null; then
    sudo -n chown "$(id -u):$(id -g)" "$SNAPSHOT_FILE" 2>/dev/null || true
fi

log_info "Snapshot dogrulaniyor..."
# etcdctl 3.6'da 'snapshot status' kaldirildi — boyut + okunabilirlik kontrolu
if [ ! -s "$SNAPSHOT_FILE" ]; then
    log_error "Snapshot bos veya olusturulamadi"
    rm -f "$SNAPSHOT_FILE" 2>/dev/null || sudo -n rm -f "$SNAPSHOT_FILE" || true
    exit 1
fi
SNAP_BYTES=$(stat -c%s "$SNAPSHOT_FILE" 2>/dev/null || echo 0)
if [ "${SNAP_BYTES:-0}" -lt 1048576 ]; then
    log_error "Snapshot suphe uyandirici kucuk (${SNAP_BYTES} byte)"
    rm -f "$SNAPSHOT_FILE" 2>/dev/null || true
    exit 1
fi
log_ok "Snapshot dogrulandi (${SNAP_BYTES} byte)"

# Depolama katmani — MAINT_STORAGE: restic | s3tier | both
case "$MAINT_STORAGE" in
    restic|both)
        if ! restic_backup_file etcd "$SNAPSHOT_FILE"; then
            log_error "restic yukleme basarisiz"
            rm -f "$SNAPSHOT_FILE"
            exit 1
        fi
        ;;
esac

case "$MAINT_STORAGE" in
    s3tier|both)
        # LEGACY tier: daily her alim; weekly/monthly donem sonu promote + prune
        log_info "Garage S3'e yukleniyor (tier)..."
        if ! s3_put "$S3_CMD" "$BUCKET" "$SNAPSHOT_FILE" "s3://${BUCKET}/etcd/daily/etcd-${TIMESTAMP}.db"; then
            log_error "S3 yukleme basarisiz (daily)"
            rm -f "$SNAPSHOT_FILE"
            exit 1
        fi
        log_ok "daily: etcd-${TIMESTAMP}.db"

        if ! s3_tier_promote "$S3_CMD" "$BUCKET" weekly etcd "$SNAPSHOT_FILE" "$TIMESTAMP"; then
            log_error "weekly promote basarisiz"
            rm -f "$SNAPSHOT_FILE"
            exit 1
        fi
        if ! s3_tier_promote "$S3_CMD" "$BUCKET" monthly etcd "$SNAPSHOT_FILE" "$TIMESTAMP"; then
            log_error "monthly promote basarisiz"
            rm -f "$SNAPSHOT_FILE"
            exit 1
        fi

        log_info "Tier prune (daily=$KEEP_DAILY weekly=$KEEP_WEEKLY monthly=$KEEP_MONTHLY)..."
        s3_tier_prune "$S3_CMD" "$BUCKET" daily etcd "$KEEP_DAILY"
        s3_tier_prune "$S3_CMD" "$BUCKET" weekly etcd "$KEEP_WEEKLY"
        s3_tier_prune "$S3_CMD" "$BUCKET" monthly etcd "$KEEP_MONTHLY"
        ;;
esac

rm -f "$SNAPSHOT_FILE"
record_backup_success "$JOB_NAME"
write_backup_metric "$JOB_NAME" 1

log_ok "etcd backup tamamlandi ($JOB_NAME, storage=$MAINT_STORAGE)"
