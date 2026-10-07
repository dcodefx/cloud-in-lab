#!/usr/bin/env bash
# restore-etcd.sh — etcd snapshot kurtarma (restic once, legacy Garage S3 fallback)
#
# =============================================================================
# K8S MASTER UZERINDE CALISIR (etcdctl, kubelet, root gerektirir)
# =============================================================================
#
# Ne yapar:  En son etcd snapshot'ini indirir, dogrular,
#            kontrol duzlemi static pod'larini (etcd/apiserver/controller-
#            manager/scheduler) kubelet'e manifest tasiyarak durdurur,
#            mevcut veriyi silmeden yedekler (rollback noktasi), snapshot'i
#            yukler, kontrol duzlemini kubelet'e tekrar baslatir.
#
# ÖNEMLİ: Bu proje PURE KUBEADM kullanır — kontrol düzlemi bileşenleri
# systemd unit'i DEĞİL, kubelet'in yönettiği static pod'lardır. Bu yüzden
# `systemctl stop/start etcd` gibi komutlar YANLIŞTIR (unit bulunamaz,
# etcd process'i gerçekte durmaz, restore çalışan verinin altından yapılır).
# Bu script bunun yerine manifest dosyalarını taşıyarak kubelet'in kendi
# pod yaşam döngüsünü tetikler ve her adımı tespit ederek (varsaymadan)
# ilerler.
#
# Kaynak secimi (sirayla denenir):
#   1. restic  — /etc/<project>/backup/etcd-<tier>.env (rol env dosyasi)
#               tier: --tier ile secilir (daily|weekly|monthly, varsayilan daily)
#   2. legacy  — Garage S3 tier/flat agaci (find_garage_latest)
#
# Kullanim ornekleri:
#   ./restore-etcd.sh                           # Menulu (onay sorar), tier=daily
#   ./restore-etcd.sh --yes                     # Onaysiz (cron/otomasyon)
#   ./restore-etcd.sh --tier weekly --yes       # Haftalik kovadan kurtar
#   ./restore-etcd.sh --bucket my-backups        # Legacy kaynak, ozel bucket
#
# UYARI: etcd snapshot geri yukleme K8s cluster'ini durdurur!
# Snapshot anindan sonraki TUM degisiklikler kaybolur.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "${SCRIPT_DIR}/_common.sh"

AUTO_YES=false
BUCKET="backups"
TIER="daily"
SNAPSHOT_FILE=""
SNAPSHOT_ID=""
CONF_DIR="/etc/${MAINT_PROJECT_NAME:-tofu-lar}"

while [[ $# -gt 0 ]]; do
    case $1 in
        --yes)          AUTO_YES=true; shift ;;
        --tier)         TIER="$2"; shift 2 ;;
        --bucket)       BUCKET="$2"; shift 2 ;;
        --creds)        GARAGE_CREDS="$2"; shift 2 ;;
        --snapshot)     SNAPSHOT_FILE="$2"; shift 2 ;;
        --snapshot-id)  SNAPSHOT_ID="$2"; shift 2 ;;
        -h|--help) echo "Kullanim: $0 [--yes] [--tier daily|weekly|monthly] [--snapshot <dosya>] [--snapshot-id <id>] [--bucket <isim>] [--creds <dosya>]"; exit 0 ;;
        *)         echo "Kullanim: $0 [--yes] [--tier daily|weekly|monthly] [--snapshot <dosya>] [--snapshot-id <id>] [--bucket <isim>] [--creds <dosya>]"; exit 1 ;;
    esac
done

case "$TIER" in
    daily|weekly|monthly) ;;
    *) log_error "--tier yalniz daily|weekly|monthly olabilir (gelen: $TIER)"; exit 1 ;;
esac

log_sep
echo "  etcd Snapshot Kurtarma (kubeadm static-pod aware)"
log_sep
echo ""

check_root

if ! command -v etcdctl &>/dev/null; then
    log_error "etcdctl bulunamadi. K8s Master uzerinde calistirin."
    exit 1
fi

log_info "Ortam doğrulanıyor (pure kubeadm / static pod varsayımı)..."
if ! assert_kubeadm_static_pods; then
    exit 1
fi
log_ok "kubelet aktif, static pod manifestleri mevcut"

mkdir -p "$TEMP_DIR"
local_file="${TEMP_DIR}/etcd-restore.db"
RESTORE_LOG="${TEMP_DIR}/etcd-restore-$(date +%Y%m%d-%H%M%S).log"

# Kaynak 0: Verilen yerel dosya
if [ -n "$SNAPSHOT_FILE" ]; then
    [ -f "$SNAPSHOT_FILE" ] || { log_error "Verilen snapshot dosyasi yok: $SNAPSHOT_FILE"; exit 1; }
    log_info "Kaynak: verilen yerel snapshot dosyasi (${SNAPSHOT_FILE})"
    cp "$SNAPSHOT_FILE" "$local_file"
fi

# Kaynak 1: restic (rol env dosyasi varsa)
if [ ! -s "$local_file" ]; then
    RESTIC_ENV="${CONF_DIR}/backup/etcd-${TIER}.env"
    if [ -f "$RESTIC_ENV" ]; then
        log_info "Kaynak: restic kovasi etcd-${TIER} (${RESTIC_ENV})"
        if ! restic_fetch_latest "$RESTIC_ENV" "$local_file" "${SNAPSHOT_ID:-latest}"; then
            log_warn "restic kaynak alimi basarisiz — legacy Garage yoluna dusuluyor"
            rm -f "$local_file"
        fi
    fi
fi

# Kaynak 2: legacy Garage S3 (tier + flat)
if [ ! -s "$local_file" ]; then
    log_info "Kaynak: legacy Garage S3 (tier + flat)"
    s3_entry=$(find_garage_latest "etcd")
    if [ -z "$s3_entry" ]; then
        log_error "Ne restic ne Garage'da etcd snapshot'i bulunamadi"
        log_info "Once su script calismali: backup/app-data/backup-etcd.sh"
        exit 1
    fi
    log_info "Garage'daki son etcd snapshot: $s3_entry"
    if ! download_from_garage "$s3_entry" "$local_file"; then
        log_error "Indirme basarisiz"
        exit 1
    fi
fi
echo ""

if [ "$AUTO_YES" = false ]; then
    log_warn "DIKKAT: etcd snapshot geri yukleme K8s cluster'ini durdurur!"
    echo "  Bu islem geri alinamaz (mevcut veri ayrica saklanir, bkz. rollback)."
    echo "  Snapshot anindan sonraki TUM degisiklikler kaybolur."
    echo ""
    read -r -p "  Devam et? (hayir/E): " CONFIRM
    [[ ! "$CONFIRM" =~ ^[Ee]$ ]] && { log_info "Iptal edildi"; exit 0; }
fi

log_info "Snapshot dogrulaniyor..."
if ! verify_etcd_snapshot "$local_file"; then
    log_error "Snapshot gecersiz"
    rm -f "$local_file"
    exit 1
fi
log_ok "Snapshot dogrulandi"

# ---------------------------------------------------------------------------
# Kontrol düzlemini durdur (manifest taşıma + gerçek durma doğrulaması)
# ---------------------------------------------------------------------------
if ! stop_control_plane_static_pods; then
    log_error "Kontrol düzlemi düzgün durdurulamadı, restore iptal edildi."
    rm -f "$local_file"
    exit 1
fi

# ---------------------------------------------------------------------------
# Pre-restore rollback noktası: mevcut veriyi SİLMEDEN yeniden adlandır.
# Restore başarısız olursa bu dizine geri dönülebilir.
# ---------------------------------------------------------------------------
ROLLBACK_DIR="/var/lib/etcd.pre-restore-$(date +%Y%m%d-%H%M%S)"
if [ -d /var/lib/etcd/member ]; then
    log_info "Mevcut etcd verisi rollback noktasına taşınıyor: $ROLLBACK_DIR"
    mv /var/lib/etcd "$ROLLBACK_DIR"
fi

restore_dir="/var/lib/etcd-restored"
log_info "Snapshot restore ediliyor..."
if ! ETCDCTL_API=3 etcdctl snapshot restore "$local_file" \
        --data-dir="$restore_dir" \
        --name=master \
        --initial-cluster=master=https://127.0.0.1:2380 \
        --initial-cluster-token=etcd-cluster 2>"$RESTORE_LOG"; then
    log_error "Restore basarisiz — rollback noktasına geri dönülüyor: $ROLLBACK_DIR"
    show_command_error "$RESTORE_LOG"
    rm -rf "$restore_dir" "$local_file"
    [ -d "$ROLLBACK_DIR" ] && mv "$ROLLBACK_DIR" /var/lib/etcd
    start_control_plane_static_pods || log_error "Kontrol düzlemi otomatik başlatılamadı, elle kontrol edin."
    exit 1
fi

mkdir -p /var/lib/etcd
mv "$restore_dir/member" /var/lib/etcd/
rm -rf "$restore_dir" "$local_file"

# ---------------------------------------------------------------------------
# Kontrol düzlemini başlat (manifest geri koy + gerçek sağlık doğrulaması)
# ---------------------------------------------------------------------------
if ! start_control_plane_static_pods; then
    log_error "Kontrol düzlemi başlatılamadı veya sağlıksız kaldı."
    log_warn "Rollback noktası hâlâ diskte duruyor: $ROLLBACK_DIR"
    log_warn "Elle kontrol: kubectl -n kube-system get pods -o wide"
    exit 1
fi

log_ok "etcd kurtarma tamamlandi"
echo ""
log_info "Rollback noktası (sorun çıkmadıysa silinebilir): $ROLLBACK_DIR"
log_info "Worker node'larda kubelet'i yeniden baslatmak gerekebilir:"
echo "  systemctl restart kubelet"
