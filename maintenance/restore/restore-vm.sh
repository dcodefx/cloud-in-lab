#!/usr/bin/env bash
# restore-vm.sh — VM/LXC image kurtarma (vzdump backup'indan)
#
# =============================================================================
# PROXMOX HOST'TA CALISIR
# =============================================================================
#
# Ne yapar:  backup/vm-disk/backup-full.sh ile alinmis vzdump image'ini
#            geri yukler. VM/LXC tipini otomatik algilar. Eskisini silmeden
#            ÖNCE arşiv bütünlüğünü doğrular — bozuk bir backup dosyası
#            yüzünden hem eski hem yeni hiçbir şeyin kalmaması riskini
#            azaltır.
#
# NOT (dürüst sınır): Restore aynı VMID'yi yeniden kullanır (Proxmox'un
# doğal akışı budur), bu yüzden eski instance, yeni restore denemesi
# BAŞARIYLA TAMAMLANMADAN önce durdurulup silinmek zorundadır. Arşiv
# bütünlük kontrolü en yaygın gerçek hata modünü (bozuk/eksik backup
# dosyası) restore denemesinden önce yakalar; ama `pct/qm restore`
# komutunun kendisi eski silindikten sonra başarısız olursa (nadir,
# ör. storage doluysa) iki taraflı kayıp mümkündür. Bu riski tamamen
# ortadan kaldırmak, aynı anda iki kopya için yeterli disk alanı ve
# farklı bir VMID stratejisi gerektirir — homelab ölçeğinde bu script
# o karmaşıklığı eklemiyor, riski açıkça belirtiyor.
#
# Kullanim ornekleri (VMID'ler ornek — kendi kurulumunuzdaki gercek ID ile):
#   ./restore-vm.sh --vmid 300                          # Garage LXC'yi kurtar
#   ./restore-vm.sh --vmid 301                          # OpenBao LXC'yi kurtar
#   ./restore-vm.sh --vmid <VMID>                       # Diger bir guest
#   ./restore-vm.sh --vmid 300 --yes                    # Onay sormadan kurtar
#   ./restore-vm.sh --vmid 300 --storage local-lvm       # Disk hedefi (thin pool)
#
# Ilgili backup scripti: backup/vm-disk/backup-full.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "${SCRIPT_DIR}/_common.sh"

VMID=""
AUTO_YES=false
STORAGE="local-lvm"
SPECIFIED_FILE=""

while [[ $# -gt 0 ]]; do
    case $1 in
        --vmid)    VMID="$2"; shift 2 ;;
        --file|--archive) SPECIFIED_FILE="$2"; shift 2 ;;
        --yes)     AUTO_YES=true; shift ;;
        --storage) STORAGE="$2"; shift 2 ;;
        -h|--help) echo "Kullanim: $0 --vmid <ID> [--file <yol>] [--yes] [--storage <isim>]"; exit 0 ;;
        *)         log_error "Kullanim: $0 --vmid <ID> [--file <yol>] [--yes] [--storage <isim>]"; exit 1 ;;
    esac
done

[ -z "$VMID" ] && { log_error "--vmid gerekli"; exit 1; }

# Yıkıcı komutların (pct/qm restore) stderr'i buraya yazılır; başarısızlıkta
# ekrana basılır. Önceden `2>/dev/null` ile tamamen yok ediliyordu — yani
# "neden başarısız oldu" bilgisi tam da en çok gerektiği anda kayboluyordu.
mkdir -p "$TEMP_DIR"
RESTORE_LOG="${TEMP_DIR}/restore-vm-$(date +%Y%m%d-%H%M%S)-${VMID}.log"

# ── Guest kimliği ve tip tespiti: önce canlı envanter, yoksa arşiv adı ──
NAME=$(vm_name "$VMID")
TYPE="$(detect_vm_type "$VMID" || true)"
if [ -n "$TYPE" ]; then
    TYPE_SOURCE="Proxmox envanteri"
else
    if TYPE="$(detect_vm_type_from_archive "$VMID")"; then
        TYPE_SOURCE="vzdump arsiv adi (guest bulunamadi)"
        log_warn "$VMID Proxmox'ta bulunamadi — tip arsiv adindan turetildi: ${TYPE}"
    else
        log_error "$VMID Proxmox'ta bulunamadi ve vzdump arsivi de yok"
        log_info "Aranan desen: vzdump-{lxc,vm}-${VMID}-*.tar.zst"
        log_info "Arama alani: ${RESTORE_BACKUP_DIR}/tier (tier) ve ${RESTORE_BACKUP_DIR} (flat)"
        exit 1
    fi
fi

log_sep
echo "  $NAME ($TYPE $VMID) Kurtarma — storage: $STORAGE"
echo "  Tip kaynagi: ${TYPE_SOURCE}"
log_sep
echo ""

if [ -n "$SPECIFIED_FILE" ]; then
    [ -f "$SPECIFIED_FILE" ] || { log_error "Belirtilen arsiv dosyasi yok: $SPECIFIED_FILE"; exit 1; }
    backup_file="$SPECIFIED_FILE"
    log_info "Belirtilen arsiv kullaniliyor: $backup_file"
else
    backup_file=$(find_latest_backup "vzdump-${TYPE}-${VMID}-*.tar.zst")
    if [ -z "$backup_file" ]; then
        log_error "${TYPE^^} $VMID backup'i bulunamadi: $RESTORE_BACKUP_DIR (tier + flat)"
        exit 1
    fi
    case "$backup_file" in
        "${RESTORE_BACKUP_DIR}/tier/"*) log_info "Son backup (tier): $backup_file" ;;
        *)                              log_info "Son backup (flat): $backup_file" ;;
    esac
fi

# ---------------------------------------------------------------------------
# Arşiv bütünlüğünü ESKİSİNİ SİLMEDEN ÖNCE doğrula — en yaygın gerçek
# hata modü (bozuk/kesik backup dosyası) burada yakalanır.
# ---------------------------------------------------------------------------
log_info "Arşiv bütünlüğü doğrulanıyor (eski instance'a dokunulmadan)..."
if ! verify_zst_archive "$backup_file"; then
    log_error "Arşiv bozuk görünüyor: $backup_file"
    log_error "Eski $NAME'e DOKUNULMADI. Başka bir backup deneyin (restore.sh list)."
    exit 1
fi
log_ok "Arşiv bütünlüğü doğrulandı"
echo ""

if [ "$AUTO_YES" = false ]; then
    read -r -p "  Bu backup'i geri yukle? (hayir/E): " CONFIRM
    [[ ! "$CONFIRM" =~ ^[Ee]$ ]] && { log_info "Iptal edildi"; exit 0; }
fi

check_root

# ---------------------------------------------------------------------------
# Başlatma sonrası doğrulama: tek seferlik varsayım yerine poll döngüsü
# ---------------------------------------------------------------------------
wait_for_running() {
    local vmid="$1" type="$2" waited=0
    while true; do
        if [ "$type" = "lxc" ]; then
            pct status "$vmid" 2>/dev/null | grep -q "running" && return 0
        else
            qm status "$vmid" 2>/dev/null | grep -q "running" && return 0
        fi
        sleep 2
        waited=$((waited + 2))
        [ "$waited" -ge 30 ] && return 1
    done
}

if [ "$TYPE" = "lxc" ]; then
    if pct list 2>/dev/null | awk 'NR>1{print $1}' | grep -qx "$VMID"; then
        if [ "$(pct status "$VMID" 2>/dev/null | grep -c "running")" -gt 0 ]; then
            log_warn "$NAME calisiyor, durduruluyor..."
            pct stop "$VMID" 2>/dev/null || true
        fi
        log_info "Eski $NAME temizleniyor..."
        pct destroy "$VMID" --purge 2>/dev/null || true
    fi
    log_info "$NAME geri yukleniyor..."
    if pct restore "$VMID" "$backup_file" --storage "$STORAGE" 2>"$RESTORE_LOG"; then
        pct start "$VMID" 2>/dev/null || true
        if wait_for_running "$VMID" "lxc"; then
            log_ok "$NAME kurtarildi ve calisiyor"
        else
            log_warn "$NAME restore edildi ama 30sn içinde 'running' durumuna geçmedi — elle kontrol edin: pct status $VMID"
        fi
        echo ""
        POST_MSG=$(vm_post_msg "$VMID")
        [ -n "$POST_MSG" ] && log_info "Sonraki adim: $POST_MSG"
    else
        log_error "Kurtarma basarisiz — eski $NAME artık mevcut değil, elle müdahale gerekiyor."
        show_command_error "$RESTORE_LOG"
        exit 1
    fi
elif [ "$TYPE" = "vm" ]; then
    if qm list 2>/dev/null | awk 'NR>1{print $1}' | grep -qx "$VMID"; then
        log_warn "Eski $NAME durdurulup silinecek..."
        qm stop "$VMID" --skiplock 2>/dev/null || true
        qm destroy "$VMID" --purge 2>/dev/null || true
    fi
    log_info "$NAME geri yukleniyor..."
    if qmrestore "$backup_file" "$VMID" --storage "$STORAGE" 2>"$RESTORE_LOG"; then
        qm start "$VMID" 2>/dev/null || true
        if wait_for_running "$VMID" "vm"; then
            log_ok "$NAME kurtarildi ve calisiyor"
        else
            log_warn "$NAME restore edildi ama 30sn içinde 'running' durumuna geçmedi — elle kontrol edin: qm status $VMID"
        fi
        echo ""
        POST_MSG=$(vm_post_msg "$VMID")
        [ -n "$POST_MSG" ] && log_info "Sonraki adim: $POST_MSG"
    else
        log_error "Kurtarma basarisiz — eski $NAME artık mevcut değil, elle müdahale gerekiyor."
        show_command_error "$RESTORE_LOG"
        exit 1
    fi
fi
