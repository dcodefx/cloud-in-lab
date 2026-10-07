#!/usr/bin/env bash
# backup-quick.sh — VM/LXC anlik ZFS snapshot
#
# =============================================================================
# PROXMOX HOST'TA CALISIR, ZFS STORAGE GEREKTIRIR
# =============================================================================
#
# Ne yapar:  ZFS ile VM/LXC disklerinin anlik goruntusunu alir.
#            Upgrade veya konfigurasyon degisikligi ONCESI manuel calistirilir.
#            Saniyeler surer, sadece degisen bloklari kaydeder.
# Ne zaman:  Upgrade oncesi manuel (cron degil)
# Retention: Son 3 snapshot korunur (--retention ile degisir; --clean ile temizler)
# Geri yukleme: Ayni script ile --rollback
#
# Kullanim ornekleri (VMID'ler ornek — kendi kurulumunuzdaki gercek ID ile calistirin):
#   ./backup-quick.sh --vmid 300              # Garage LXC snapshot al
#   ./backup-quick.sh --vmid 301 --list       # Mevcut snapshot'lari listele
#   ./backup-quick.sh --vmid 300 --rollback   # Son snapshot'a don
#   ./backup-quick.sh --vmid 300 --clean       # Eski snapshot'lari temizle
#   ./backup-quick.sh --vmid 300 --retention 5 --clean  # Son 5'i birak
#
# vs vzdump (backup-full.sh):
#   backup-full.sh  = haftalik, dosyaya yazar, dakikalar, felaket kurtarma
#   backup-quick.sh = upgrade once, ZFS icinde, saniyeler, hizli geri donus

set -euo pipefail

VMID=""
MODE="snapshot"
SNAPSHOT_PREFIX="pre-upgrade"
RETENTION_COUNT=3

log_info() { echo "[INFO]  $*"; }
log_ok()   { echo "[OK]    $*"; }
log_warn() { echo "[WARN]  $*" >&2; }
log_error(){ echo "[HATA]  $*" >&2; }

usage() {
    echo "Kullanim: $0 --vmid <ID> [--list|--rollback|--clean] [--retention <n>]"
    echo ""
    echo "  --vmid <ID>      VM veya CT ID (ornek: 300, 301)"
    echo "  --list           Mevcut snapshot'lari listele"
    echo "  --rollback       Son snapshot'a geri don"
    echo "  --clean          Eski snapshot'lari temizle (son $RETENTION_COUNT disinda)"
    echo "  --retention <n>  --clean ile korunacak snapshot sayisi (varsayilan: 3)"
    exit 1
}

while [[ $# -gt 0 ]]; do
    case $1 in
        --vmid)      VMID="$2"; shift 2 ;;
        --list)      MODE="list"; shift ;;
        --rollback)  MODE="rollback"; shift ;;
        --clean)     MODE="clean"; shift ;;
        --retention) RETENTION_COUNT="$2"; shift 2 ;;
        *)           usage ;;
    esac
done

[ -z "$VMID" ] && { log_error "--vmid gerekli"; usage; }

# ZFS dataset'ini bul
ZFS_DATASET=$(zfs list -H -o name 2>/dev/null | grep -i "vm-${VMID}-disk" | head -1 || true)
if [ -z "$ZFS_DATASET" ]; then
    log_error "$VMID icin ZFS dataset bulunamadi."
    log_info "Mevcut ZFS dataset'leri:"
    zfs list -H -o name 2>/dev/null | grep -i "vm-.*-disk" || true
    exit 1
fi

# VM/LXC tipini bul (rollback icin)
if pct list 2>/dev/null | awk 'NR>1{print $1}' | grep -qx "$VMID"; then
    CTL="pct"
elif qm list 2>/dev/null | awk 'NR>1{print $1}' | grep -qx "$VMID"; then
    CTL="qm"
else
    CTL=""
fi

case "$MODE" in
    snapshot)
        TIMESTAMP=$(date +%Y%m%d-%H%M%S)
        SNAPSHOT_NAME="${ZFS_DATASET}@${SNAPSHOT_PREFIX}-${TIMESTAMP}"
        log_info "ZFS snapshot aliniyor: $SNAPSHOT_NAME"
        if zfs snapshot -r "$SNAPSHOT_NAME"; then
            log_ok "Snapshot alindi: $SNAPSHOT_NAME"
        else
            log_error "Snapshot basarisiz"
            exit 1
        fi
        ;;

    list)
        log_info "$VMID mevcut snapshot'lar:"
        zfs list -H -t snapshot -o name,creation | grep "vm-${VMID}-disk" || echo "  (snapshot yok)"
        ;;

    rollback)
        LATEST=$(zfs list -H -t snapshot -o name | grep "vm-${VMID}-disk.*${SNAPSHOT_PREFIX}" | sort | tail -1 || true)
        if [ -z "$LATEST" ]; then
            log_error "Geri donulecek snapshot bulunamadi"
            exit 1
        fi
        log_warn "$VMID son snapshot'a ($LATEST) geri donuluyor..."
        echo "  UYARI: Bu islem VM/LXC'yi o anki haline dondurur."
        echo "  Aradaki tum degisiklikler KAYBOLUR."
        read -p "  Devam et? (hayir/E): " CONFIRM
        if [[ "$CONFIRM" =~ ^[Ee]$ ]]; then
            if [ -n "$CTL" ]; then
                "$CTL" stop "$VMID" 2>/dev/null || true
            fi
            zfs rollback -r "$LATEST"
            if [ -n "$CTL" ]; then
                "$CTL" start "$VMID" 2>/dev/null || true
            fi
            log_ok "Rollback tamamlandi: $LATEST"
        else
            log_info "Iptal edildi"
        fi
        ;;

    clean)
        log_info "Eski snapshot'lar temizleniyor (son $RETENTION_COUNT disinda)..."
        ALL_SNAPS=$(zfs list -H -t snapshot -o name | grep "vm-${VMID}-disk.*${SNAPSHOT_PREFIX}" | sort)
        COUNT=$(echo "$ALL_SNAPS" | wc -l)
        if [ "$COUNT" -le "$RETENTION_COUNT" ]; then
            log_info "Temizlik gerekmiyor ($COUNT snapshot, limit $RETENTION_COUNT)"
        else
            TO_DELETE=$(echo "$ALL_SNAPS" | head -n $((COUNT - RETENTION_COUNT)))
            echo "$TO_DELETE" | while read -r snap; do
                [ -n "$snap" ] && zfs destroy "$snap" && echo "  Silindi: $snap"
            done
            log_ok "Temizlik tamamlandi"
        fi
        ;;
esac
