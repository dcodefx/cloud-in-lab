#!/usr/bin/env bash
# restore.sh — Seçimli kurtarma ana menusu
#
# =============================================================================
# PROXMOX HOST'TA CALISIR
# =============================================================================
#
# Ne yapar:  Tum kurtarma islemlerini tek noktadan yonetir.
#            Menuden secim yapilabilir veya dogrudan parametre verilebilir.
#
# Kullanim ornekleri (VMID'ler ornek — kendi kurulumunuzdaki gercek ID ile):
#   ./restore.sh                                # Menuyu goster
#   ./restore.sh vm 300                         # Garage LXC'yi kurtar
#   ./restore.sh vm 301 --yes                   # OpenBao'yu onaysiz kurtar
#   ./restore.sh vm <VMID>                      # Ornek disi bir VM/LXC'yi kurtar
#   ./restore.sh etcd                           # etcd snapshot kurtar
#   ./restore.sh etcd --yes                     # etcd onaysiz kurtar
#   ./restore.sh all                            # TUMUNU kurtar
#   ./restore.sh list                           # Mevcut yedekleri goster
#   ./restore.sh health                         # Backup freshness durumu

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "${SCRIPT_DIR}/_common.sh"

# Renkli menu (TERM destekliyorsa)
if [ -t 1 ] && [ "$(tput colors 2>/dev/null || echo 0)" -ge 8 ]; then
    BOLD="$(tput bold)"
    GREEN="$(tput setaf 2)"
    YELLOW="$(tput setaf 3)"
    RED="$(tput setaf 1)"
    CYAN="$(tput setaf 6)"
    RESET="$(tput sgr0)"
else
    BOLD=""; GREEN=""; YELLOW=""; RED=""; CYAN=""; RESET=""
fi

show_backup_list() {
    log_sep
    echo "  Mevcut Yedekler (Proxmox local — tier + flat)"
    log_sep
    local found=0
    local f sz rel
    while IFS= read -r f; do
        [ -n "$f" ] || continue
        found=1
        sz=$(du -h "$f" 2>/dev/null | cut -f1)
        rel="${f#/var/lib/vz/dump/}"
        echo "  $rel  (${sz})"
    done < <(find "${RESTORE_BACKUP_DIR}" -name "vzdump-*.tar.zst" -type f 2>/dev/null | sort)

    if [ "$found" -eq 0 ]; then
        echo "  (Proxmox local uzerinde .tar.zst yedeği bulunamadi)"
    fi

    # Tier ozet (varsa)
    if [ -d /var/lib/vz/dump/tier ]; then
        echo ""
        echo "  Tier ozet:"
        for t in weekly monthly; do
            n=$(find "/var/lib/vz/dump/tier/$t" -maxdepth 1 -type f 2>/dev/null | wc -l)
            echo "    $t: $n dosya"
        done
    fi
    echo ""
    log_sep
    echo "  Mevcut Yedekler (Garage S3 — tier + flat legacy)"
    log_sep
    for prefix in "etcd" "openbao"; do
        s3_entry=$(find_garage_latest "$prefix" 2>/dev/null || true)
        if [ -n "$s3_entry" ]; then
            echo "  $s3_entry"
        fi
    done
}

show_health() {
    "${SCRIPT_DIR}/../backup/healthcheck.sh"
}

show_menu() {
    log_sep
    echo "  ${BOLD}${GREEN}tofu-lar Kurtarma Menusu${RESET}"
    log_sep
    echo ""
    echo "  ${CYAN}1)${RESET} VM / LXC Kurtar          — disk goruntusunden kurtar (Garage, OpenBao vb.)"
    echo "  ${CYAN}2)${RESET} etcd Snapshot           — S3/restic'ten etcd snapshot yukle (kubelet-aware)"
    echo "  ${CYAN}3)${RESET} Raft Snapshot           — OpenBao verisini raft snapshot anina dondur"
    echo "  ${CYAN}4)${RESET} TUMUNU Kurtar           — VM/LXC ve etcd snapshot'i sirasiyla kurtar"
    echo "  ${CYAN}l)${RESET} Listele                 — Mevcut yedekleri goster"
    echo "  ${CYAN}h)${RESET} Sağlık                  — Backup freshness durumu"
    echo "  ${CYAN}q)${RESET} Cikis"
    echo ""
    echo "  ${YELLOW}Not:${RESET} VM / LXC disk kurtarma vs Raft Snapshot:"
    echo "    1) = Guest'in TAMAMI diskten geri gelir."
    echo "    3) = LXC/VM saglam, raft verisi bozukken; guest'e dokunmadan"
    echo "         OpenBao'yu secilen snapshot anina dondurur."
    echo ""
}

run_menu() {
    while true; do
        show_menu
        read -r -p "  ${BOLD}Secim${RESET} [1-4/l/h/q]: " CHOICE
        echo ""
        case "$CHOICE" in
            1)
                read -r -p "  Kurtarilacak VM/LXC ID [varsayilan: 300]: " USER_VMID
                USER_VMID="${USER_VMID:-300}"
                "${SCRIPT_DIR}/restore-vm.sh" --vmid "$USER_VMID"
                ;;
            2) "${SCRIPT_DIR}/restore-etcd.sh" ;;
            3) "${SCRIPT_DIR}/restore-openbao.sh" ;;
            4)
                log_warn "Tumunu kurtarma baslatiliyor..."
                echo "  ${RED}Bu islem cluster'i etkiler. Geri alinamaz.${RESET}"
                echo "  Proxmox backup = eski haline doner."
                echo "  etcd snapshot = son yedek anina doner."
                echo "  Arasindaki tum degisiklikler KAYBOLUR."
                echo ""
                read -r -p "  Kurtarilacak VMID listesi (boslukla ayrilmis) [varsayilan: 300 301]: " VMID_LIST
                VMID_LIST="${VMID_LIST:-300 301}"
                read -r -p "  Emin misiniz? (Evet/Hayir): " CONFIRM
                if [[ "$CONFIRM" =~ ^[Ee] ]]; then
                    for vmid in $VMID_LIST; do
                        "${SCRIPT_DIR}/restore-vm.sh" --vmid "$vmid" --yes
                    done
                    "${SCRIPT_DIR}/restore-etcd.sh" --yes
                else
                    log_info "Iptal edildi"
                fi
                ;;
            l|L) show_backup_list ;;
            h|H) show_health ;;
            q|Q) log_info "Cikiliyor"; exit 0 ;;
            *)   log_warn "Gecersiz secim: $CHOICE" ;;
        esac
        echo ""
        read -r -p "  Devam etmek icin Enter'a basin..."
    done
}

case "${1:-menu}" in
    menu)           run_menu ;;
    list)           show_backup_list ;;
    health)         show_health ;;
    vm)
        VMID="${2:-}"
        [ -z "$VMID" ] && { log_error "Kullanim: $0 vm <VMID> [--yes]"; exit 1; }
        shift 2
        "${SCRIPT_DIR}/restore-vm.sh" --vmid "$VMID" "$@"
        ;;
    etcd)
        shift
        "${SCRIPT_DIR}/restore-etcd.sh" "$@"
        ;;
    raft)
        shift
        "${SCRIPT_DIR}/restore-openbao.sh" "$@"
        ;;
    all)
        shift
        AUTO_YES=false
        TARGET_VMIDS=()
        while [[ $# -gt 0 ]]; do
            case "$1" in
                --yes) AUTO_YES=true; shift ;;
                *) TARGET_VMIDS+=("$1"); shift ;;
            esac
        done
        if [ ${#TARGET_VMIDS[@]} -eq 0 ]; then
            TARGET_VMIDS=(300 301)
        fi
        if [ "$AUTO_YES" = false ]; then
            read -r -p "  TUMUNU kurtar? (${TARGET_VMIDS[*]}) (Evet/Hayir): " CONFIRM
            [[ ! "$CONFIRM" =~ ^[Ee] ]] && { log_info "Iptal"; exit 0; }
        fi
        for vmid in "${TARGET_VMIDS[@]}"; do
            echo ""
            "${SCRIPT_DIR}/restore-vm.sh" --vmid "$vmid" --yes
        done
        echo ""
        "${SCRIPT_DIR}/restore-etcd.sh" --yes
        ;;
    *)
        echo "Kullanim: $0 [vm <VMID>|etcd|raft|all [<VMID>...]|list|health|menu]"
        echo ""
        echo "  $0              — Menuyu goster"
        echo "  $0 vm <VMID>    — Belirtilen VMID (LXC veya QEMU) diskini kurtar"
        echo "  $0 etcd         — etcd snapshot kurtar"
        echo "  $0 raft         — OpenBao raft snapshot geri yukle"
        echo "                   --tier daily|weekly|monthly | --snapshot <file> | --snapshot-id <id>"
        echo "  $0 all          — VM/LXC ve etcd snapshot'larini kurtar"
        echo "  $0 list         — Yedekleri listele"
        echo "  $0 health       — Backup freshness durumu"
        exit 1
        ;;
esac
