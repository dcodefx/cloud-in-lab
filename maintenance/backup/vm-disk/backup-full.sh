#!/usr/bin/env bash
# backup-full.sh — VM/LXC tam disk goruntusu (vzdump ile) + local tier
#
# =============================================================================
# PROXMOX HOST'TA CALISIR
# =============================================================================
#
# Ne yapar:  vzdump ile VM/LXC'nin tam disk image'ini alir,
#            /var/lib/vz/dump/ altina .tar.zst olarak kaydeder,
#            weekly/monthly tier klasorune kopyalar (cloud/S3 YOK),
#            tier prune uygular
# Ne zaman:  Haftalik (cron: 0 3 * * 0)
# Retention: flat find (28 gun) + tier weekly 3 / monthly 3
# Geri yukleme: restore/restore-vm.sh --vmid <ID>
#
# Tier notu: disk yedegi icin daily YOK (plan: sadece weekly + monthly,
#            cloud/S3'e yukleme yok — yalniz PVE local).
#
# Kullanim ornekleri (VMID'ler ornek — kendi kurulumunuzdaki gercek ID ile calistirin):
#   ./backup-full.sh --vmid 300             # Garage LXC'yi yedekle
#   ./backup-full.sh --vmid 301             # OpenBao LXC'yi yedekle
#   ./backup-full.sh --vmid 300 --dry-run   # Sadece goster
#   ./backup-full.sh --vmid 300 --retention 14   # flat find retention (gun)
#   ./backup-full.sh --vmid 300 --no-retention   # find retention'ini atla
#   ./backup-full.sh --vmid 300 --prune-backups keep-last=4
#   ./backup-full.sh --vmid 300 --storage pbs-store  # Ozel storage (dosya seviyesi)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "${SCRIPT_DIR}/../../_common.sh"

VMID=""
STORAGE="local"
RETENTION_DAYS=28
DRY_RUN=false
NO_RETENTION=false
PRUNE_BACKUPS=""
KEEP_WEEKLY=3
KEEP_MONTHLY=3

usage() {
    echo "Kullanim: $0 --vmid <ID> [--storage <storage>] [--retention <gun>] [--no-retention] [--prune-backups <kural>] [--dry-run]"
    echo ""
    echo "  --vmid <ID>              VM veya CT ID (ornek: 300, 301)"
    echo "  --storage <ad>           Proxmox dosya seviyesi storage (varsayilan: local)"
    echo "  --retention <gun>        flat find ile kac gun saklanacak (varsayilan: 28)"
    echo "  --no-retention           find retention'ini calistirme (tier prune yine uygulanir)"
    echo "  --prune-backups <kural>  vzdump --prune-backups (orn: keep-last=4); find atlanir"
    echo "  --dry-run                Calistirmadan goster"
    echo ""
    echo "  Tier: ${KEEP_WEEKLY} weekly / ${KEEP_MONTHLY} monthly (yalniz local, cloud yok)"
    echo "  Not: --no-retention ve --prune-backups birlikte anlamsiz; prune verilirse find kullanilmaz."
    exit 1
}

while [[ $# -gt 0 ]]; do
    case $1 in
        --vmid)           VMID="$2"; shift 2 ;;
        --storage)        STORAGE="$2"; shift 2 ;;
        --retention)      RETENTION_DAYS="$2"; shift 2 ;;
        --no-retention)   NO_RETENTION=true; shift ;;
        --prune-backups)  PRUNE_BACKUPS="$2"; shift 2 ;;
        --dry-run)        DRY_RUN=true; shift ;;
        *)                usage ;;
    esac
done

[ -z "$VMID" ] && { log_error "--vmid gerekli"; usage; }

if [ "$NO_RETENTION" = true ] && [ -n "$PRUNE_BACKUPS" ]; then
    log_warn "--no-retention ve --prune-backups birlikte verildi; --prune-backups uygulanir, find atlanir."
    NO_RETENTION=false
fi

DUMP_DIR="/var/lib/vz/dump"
TIER_ROOT="${DUMP_DIR}/tier"

VZDUMP_ARGS=(--mode snapshot --compress zstd --storage "$STORAGE")
if [ -n "$PRUNE_BACKUPS" ]; then
    VZDUMP_ARGS+=(--prune-backups "$PRUNE_BACKUPS")
fi

# dry-run: pct/qm/vzdump tespitinden ONCE plan gosterip cik (localden de calisir)
if [ "$DRY_RUN" = true ]; then
    log_info "[DRY-RUN] Asagidaki komut calistirilacak (PVE uzerinde):"
    echo "  vzdump $VMID ${VZDUMP_ARGS[*]} --notes-template <ad - tarih>"
    if [ "$NO_RETENTION" = true ]; then
        echo "  Flat retention: atlandi (--no-retention)"
    elif [ -n "$PRUNE_BACKUPS" ]; then
        echo "  Flat retention: vzdump --prune-backups $PRUNE_BACKUPS"
    else
        echo "  Flat retention: $RETENTION_DAYS gun sonra eski backup'lar silinecek (find)"
    fi
    echo "  Tier: ${TIER_ROOT}/weekly (keep $KEEP_WEEKLY), ${TIER_ROOT}/monthly (keep $KEEP_MONTHLY) — local only"
    echo "  Hedef: $STORAGE storage (arsiv dosya seviyesinde olmali)"
    exit 0
fi

# VM/LXC tipini ve adini bul (gerçek mod — pct/qm gerektirir)
if pct list 2>/dev/null | awk 'NR>1{print $1}' | grep -qx "$VMID"; then
    TYPE="lxc"
    NAME="CT $VMID"
elif qm list 2>/dev/null | awk 'NR>1{print $1}' | grep -qx "$VMID"; then
    TYPE="vm"
    NAME="VM $VMID"
else
    log_error "$VMID bulunamadi. Liste:"
    pct list 2>/dev/null || true
    qm list 2>/dev/null || true
    exit 1
fi

BACKUP_FILE="vzdump-${TYPE}-${VMID}-$(date +%Y_%m_%d-%H_%M_%S).tar.zst"
NOTES="${NAME} - $(date +%Y-%m-%d)"
VZDUMP_ARGS+=(--notes-template "$NOTES")

log_info "$NAME yedekleniyor (storage: $STORAGE)..."
if ! vzdump "$VMID" "${VZDUMP_ARGS[@]}"; then
    log_error "vzdump basarisiz ($NAME)"
    exit 1
fi

log_ok "$NAME yedeklendi"

# vzdump'un yazdigi flat dosyayi bul (en yeni, bu calistirma)
FOUND_FILE="$(find "$DUMP_DIR" -maxdepth 1 -name "vzdump-${TYPE}-${VMID}*.tar.zst" -type f 2>/dev/null | sort | tail -1 || true)"
if [ -z "$FOUND_FILE" ]; then
    log_error "vzdump dosyasi bulunamadi: $DUMP_DIR/vzdump-${TYPE}-${VMID}*.tar.zst"
    exit 1
fi

# Local tier: weekly + monthly (cloud/S3 yok). Damga vzdump underscore formundan turetilir.
STAMP="$(tier_stamp_from_name "$(basename "$FOUND_FILE")")"
if [ -z "$STAMP" ]; then
    log_warn "Dosyadan damga okunamadi, tier promote atlandi: $(basename "$FOUND_FILE")"
else
    log_info "Tier promote (weekly/monthly, local)..."
    tier_write_local "${TIER_ROOT}/weekly"  "$FOUND_FILE" "$STAMP" "-weekly"
    tier_write_local "${TIER_ROOT}/monthly" "$FOUND_FILE" "$STAMP" "-monthly"
    tier_prune "${TIER_ROOT}/weekly"  "$KEEP_WEEKLY"
    tier_prune "${TIER_ROOT}/monthly" "$KEEP_MONTHLY"
fi

# Flat retention: eski backup'lari temizle (tier klasorleri etkilenmez — maxdepth 1)
if [ "$NO_RETENTION" = true ]; then
    log_info "Flat retention atlandi (--no-retention)"
elif [ -n "$PRUNE_BACKUPS" ]; then
    log_info "Flat retention vzdump --prune-backups ile uygulandi: $PRUNE_BACKUPS"
else
    if [ -d "$DUMP_DIR" ]; then
        log_info "$RETENTION_DAYS gunden eski flat backup'lar temizleniyor..."
        find "$DUMP_DIR" -maxdepth 1 -name "vzdump-${TYPE}-${VMID}*.tar.zst" -mtime "+${RETENTION_DAYS}" -delete 2>/dev/null || true

        REMAINING=$(find "$DUMP_DIR" -maxdepth 1 -name "vzdump-${TYPE}-${VMID}*.tar.zst" 2>/dev/null | wc -l)
        log_ok "$REMAINING flat backup dosyasi korunuyor"
    fi
fi

record_backup_success "vm-disk-${VMID}"
