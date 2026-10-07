#!/usr/bin/env bash
# backup-openbao.sh — OpenBao raft snapshot alir; depolama katmanina yukler
#
# =============================================================================
# OPENBAO LXC (CT 301) UZERINDE CALISIR (bao komutu gerektirir)
# =============================================================================
#
# Depolama modu (MAINT_STORAGE env'i — systemd EnvironmentFile'indan gelir):
#   restic  → restic repoya yukler (sifrele+dedup+keep-last N) — YENI mimari
#   s3tier  → Garage S3 tier agacina yukler (daily/weekly/monthly) — LEGACY
#   both    → ikisi birden (shadow gecis donemi)
# Varsayilan: s3tier (elle/cron kullanimi geriye uyumlu).
#
# Retansiyon: restic → KEEP_LAST (env); s3tier → daily 3 / weekly 3 / monthly 3
# .state kaydi: JOB_NAME env'i (rol: openbao-daily|openbao-weekly|openbao-monthly)
# UYARI: Unseal key'ler asla ayni yerde (S3/password) saklanmamali!
#   raft snapshot -> Garage S3 / restic (bu script ile)
#   unseal key     -> password manager (AYRI bir kanal)
#
# KIMLIK (2026-09-28, session-080 degisimi): root token KALDIRILDI.
#   Onceki: BAO_TOKEN / openbao-credentials.yml (openbao_root_token) okunuyordu.
#   Simdi:  `bao agent` (auto_auth/AppRole, role: bao-raft-agent) unix socket
#           uzerinden kimligi yonetir; bu script HICBIR token tasimaz.
#   Policy/roller: docs/tr/openbao/openbao-rbac.md B10 (read-only) / P14.
#   NOT: bu dizin openbao-raft-agent.service.j2 + server/defaults/main.yml
#   (openbao_raft_snap_dir) ile ayni deger olmak ZORUNDA — tek kaynak script.
#
# YEREL KOPYA: /tmp DEGIL kalici dizin. 7 gun tutulur (retention asagida).
#   Ayni anda iki kopya bulunur:
#     1) yerel  : /var/lib/bao-raft-snaps/  (hizli restore, CT301 kaybinda hayatta kalir)
#     2) uzak   : restic -> Garage2 openbao-daily|weekly|monthly (sifreli)
#   Geri yukleme: maintenance/restore/restore-openbao.sh (restic'ten ceker +
#   API'ye yukler) veya tam CT: restore/restore-vm.sh --vmid 301.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "${SCRIPT_DIR}/../../_common.sh"

BUCKET="backups"
DRY_RUN=false
KEEP_DAILY=3
KEEP_WEEKLY=3
KEEP_MONTHLY=3
MAINT_STORAGE="${MAINT_STORAGE:-s3tier}"
JOB_NAME="${JOB_NAME:-openbao}"
# Kalici yerel kopya dizini. openbao_raft_snap_dir ile ayni olmali.
BACKUP_DIR="${RAFT_SNAP_DIR:-/var/lib/bao-raft-snaps}"
SNAP_RETENTION_DAYS="${RAFT_SNAP_RETENTION_DAYS:-7}"
# Agent unix socket (roles/openbao/server: openbao_raft_agent_sock).
BAO_AGENT_SOCK="${BAO_AGENT_SOCK:-/etc/bao/agent.sock}"

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

# dry-run: bagimlilik (bao/s3/health) kontrolunden ONCE plan gosterip cik
if [ "$DRY_RUN" = true ]; then
    TIMESTAMP=$(date +%Y%m%d-%H%M%S)
    log_info "[DRY-RUN] raft snapshot alinacak -> ${BACKUP_DIR}/raft-snapshot-${TIMESTAMP}.snap"
    case "$MAINT_STORAGE" in
        restic)
            echo "  restic: \${RESTIC_REPOSITORY} (keep-last ${KEEP_LAST:-3})" ;;
        s3tier)
            echo "  Yuklenecek: s3://${BUCKET}/openbao/daily/raft-snapshot-${TIMESTAMP}.snap"
            echo "  Tier prune: daily=$KEEP_DAILY weekly=$KEEP_WEEKLY monthly=$KEEP_MONTHLY" ;;
        both)
            echo "  restic: \${RESTIC_REPOSITORY} (keep-last ${KEEP_LAST:-3})"
            echo "  Yuklenecek: s3://${BUCKET}/openbao/daily/raft-snapshot-${TIMESTAMP}.snap" ;;
    esac
    echo "  Yerel kopya: ${BACKUP_DIR} (retention ${SNAP_RETENTION_DAYS} gun)"
    echo "  Kimlik: bao agent unix socket (${BAO_AGENT_SOCK}) — token yok"
    exit 0
fi

if ! command -v bao &>/dev/null; then
    log_error "bao bulunamadi. OpenBao LXC uzerinde calistirin."
    exit 1
fi

case "$MAINT_STORAGE" in
    s3tier|both)
        S3_CMD="$(detect_s3_cmd)"
        if [ -z "$S3_CMD" ]; then
            if [ -x "${HOME}/bin/aws" ]; then
                S3_CMD="aws"
                export PATH="${HOME}/bin:${PATH}"
            elif [ -x /usr/local/bin/aws ]; then
                S3_CMD="aws"
                export PATH="/usr/local/bin:${PATH}"
            else
                log_error "s3cmd veya aws CLI bulunamadi"
                exit 1
            fi
        fi

        if ! load_garage_creds; then
            exit 1
        fi
        ;;
esac

# ── Kimlik: root token YOK ───────────────────────────────────────────────
# Token kaskadi (BAO_TOKEN -> openbao-credentials.yml openbao_root_token)
# 2026-09-28'de KALDIRILDI. Yerine: `bao agent` auto_auth (AppRole
# bao-raft-agent) unix socket uzerinden yetkilendiriyor. Token bu script'te
# hicbir noktada gecerli degil — ne okunur ne yazilir ne loglanir.
#
# Socket yoksa daha erken ve daha anlasilir hata ver: BAO_ADDR'i TCP'ye
# cevirmek sessizce geri duser (dosyada hardcoded IP vardi, o da kalkti).
if [ ! -S "$BAO_AGENT_SOCK" ]; then
    log_error "bao agent socket bulunamadi: ${BAO_AGENT_SOCK}"
    log_info "Servis durumu: systemctl status bao-raft-agent"
    log_info "Dagitim: ansible-playbook playbooks/openbao.yml (openbao_backup_enabled: true olmali)"
    exit 1
fi
export BAO_ADDR="unix://${BAO_AGENT_SOCK}"

# Unsealed mi? `bao status` cikis kodu: 0=unsealed, 1=hata, 2=sealed.
# Ham curl KULLANILMAZ — `bao status` tercih edildi, üç gerekçe:
#   1) dosyada hardcoded IP vardı (https://164.102.98.186:8200) → kaldırıldı
#   2) self-signed sertifika: curl -k gerekiyordu, CLI da öyle ama tek yerde
#   3) sealed tespiti HTTP koduna değil cikis koda bakıyor (0/1/2) — daha okunur
# NOT (düzeltme): agent listener'inda `require_request_header` varsayılanı FALSE
# (openbao.org/docs/agent-and-proxy/agent) — yani 412 zorunlu değil ve ham curl
# da çalışırdı. Daha önce "X-Vault-Request olmadan 412 döner" diye yazılmıştı,
# bu yanlıştı: 412 yalnız require_request_header = true iken oluşur.
log_info "OpenBao durum kontrol ediliyor (agent: ${BAO_AGENT_SOCK})..."
set +e
bao status >/dev/null 2>&1
BAO_STATUS_RC=$?
set -e
case "$BAO_STATUS_RC" in
    0) log_ok "OpenBao unsealed" ;;
    2)
        log_error "OpenBao sealed. Raft snapshot sealed instance'ta calismaz."
        log_info "Once unseal edin: scripts/openbao-unseal/unseal.sh"
        exit 1
        ;;
    *)
        log_error "OpenBao erisilemez (bao status rc=${BAO_STATUS_RC}). LXC + agent calisiyor mu?"
        exit 1
        ;;
esac

mkdir -p "$BACKUP_DIR"
TIMESTAMP=$(date +%Y%m%d-%H%M%S)
SNAPSHOT_FILE="${BACKUP_DIR}/raft-snapshot-${TIMESTAMP}.snap"

log_info "Raft snapshot aliniyor: $SNAPSHOT_FILE"
# TLS atlayan bayraklar kalkti: unix socket'te TLS yok (BAO_TLS_SKIP/
# BAO_SNAP_OPTS ve -tls-skip-verify emekli).
if ! bao operator raft snapshot save "$SNAPSHOT_FILE"; then
    log_error "Raft snapshot basarisiz"
    rm -f "$SNAPSHOT_FILE"
    exit 1
fi

# Boyut sifir/cok kucukse (bozuk olabilir) uyar
SNAP_BYTES=$(stat -c%s "$SNAPSHOT_FILE" 2>/dev/null || stat -f%z "$SNAPSHOT_FILE" 2>/dev/null || echo 0)
if [ "$SNAP_BYTES" -lt 1024 ]; then
    log_error "Snapshot suphe uyandirici kucuk (${SNAP_BYTES} byte). Yukleme durduruldu."
    rm -f "$SNAPSHOT_FILE"
    exit 1
fi

BOYUT=$(du -h "$SNAPSHOT_FILE" | cut -f1)
log_ok "Raft snapshot alindi (${BOYUT})"

# Depolama katmani — MAINT_STORAGE: restic | s3tier | both
# Yukleme basarisiz olursa YEREL KOPYA SILINMEZ: o an elimizdeki tek snapshot
# o. Eski davranis (rm -f) tek kopyayi yok ediyordu; duzeltildi.
case "$MAINT_STORAGE" in
    restic|both)
        if ! restic_backup_file openbao "$SNAPSHOT_FILE"; then
            log_error "restic yukleme basarisiz"
            log_warn "Yerel kopya KORUNDU: $SNAPSHOT_FILE"
            exit 1
        fi
        ;;
esac

case "$MAINT_STORAGE" in
    s3tier|both)
        # LEGACY tier: daily her alim; weekly/monthly donem sonu promote + prune
        log_info "Garage S3'e yukleniyor (tier)..."
        if ! s3_put "$S3_CMD" "$BUCKET" "$SNAPSHOT_FILE" "s3://${BUCKET}/openbao/daily/raft-snapshot-${TIMESTAMP}.snap"; then
            log_error "S3 yukleme basarisiz (daily)"
            rm -f "$SNAPSHOT_FILE"
            exit 1
        fi
        log_ok "daily: raft-snapshot-${TIMESTAMP}.snap"

        if ! s3_tier_promote "$S3_CMD" "$BUCKET" weekly openbao "$SNAPSHOT_FILE" "$TIMESTAMP"; then
            log_error "weekly promote basarisiz"
            rm -f "$SNAPSHOT_FILE"
            exit 1
        fi
        if ! s3_tier_promote "$S3_CMD" "$BUCKET" monthly openbao "$SNAPSHOT_FILE" "$TIMESTAMP"; then
            log_error "monthly promote basarisiz"
            rm -f "$SNAPSHOT_FILE"
            exit 1
        fi

        log_info "Tier prune (daily=$KEEP_DAILY weekly=$KEEP_WEEKLY monthly=$KEEP_MONTHLY)..."
        s3_tier_prune "$S3_CMD" "$BUCKET" daily openbao "$KEEP_DAILY"
        s3_tier_prune "$S3_CMD" "$BUCKET" weekly openbao "$KEEP_WEEKLY"
        s3_tier_prune "$S3_CMD" "$BUCKET" monthly openbao "$KEEP_MONTHLY"
        ;;
esac

# Snapshot SILINMEZ: kalici yerel kopya bu. Eski davranis "yukle → rm -f"
# idi (gecici tampon); artik iki kopya hedefi var (yerel + uzak).
# 3 job ayni dizini paylasir (openbao-daily 02:00, weekly Paz 04:00,
# monthly ayin1 04:30) — dosya adinda TIMESTAMP var, cakisma olmaz;
# find -mtime +N hepsini birlikte temizler.
find "$BACKUP_DIR" -name 'raft-snapshot-*.snap' -mtime +"${SNAP_RETENTION_DAYS}" -delete 2>/dev/null || true
SNAP_COUNT=$(find "$BACKUP_DIR" -name 'raft-snapshot-*.snap' 2>/dev/null | wc -l)
log_info "Yerel kopya: ${BACKUP_DIR} (${SNAP_COUNT} dosya, retention ${SNAP_RETENTION_DAYS} gun)"

record_backup_success "$JOB_NAME"
write_backup_metric "$JOB_NAME" 1

log_ok "OpenBao backup tamamlandi ($JOB_NAME, storage=$MAINT_STORAGE, yerel=$SNAPSHOT_FILE)"
