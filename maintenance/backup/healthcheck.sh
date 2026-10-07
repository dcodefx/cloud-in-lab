#!/usr/bin/env bash
# healthcheck.sh — Backup'larin ne zaman son kez basarili oldugunu raporlar
#
# =============================================================================
# HERHANGI BIR YERDE CALISIR (backup script'lerinin state dosyalarina erisimi olmali)
# =============================================================================
#
# Ne yapar:  Her backup script'inin (etcd, openbao, vm-disk-<ID>) son basarili
#            calisma zaman damgasini okur, ritim (interval) + tolerans esigini
#            asanlari [SORUN] isaretler ve exit 1 dondurur. Cron log'lari kimse
#            okumadigi icin sessizce basarisiz olan backup'lari yakalamak
#            icindir.
# Ne zaman:  Gunluk (cron: 0 8 * * *) — ciktisi mail/monitoring'e baglanabilir
#
# Esik: son_success + interval + tolerance > simdi ise sorun yok.
# Ornek etcd: 4s ritim + 2s tolerans = 6s esik (var olan davranisla ayni).
#
# Kullanim:
#   ./healthcheck.sh              # Durumu yazdir, biri eskiyse exit 1
#   ./healthcheck.sh --quiet      # Sadece sorun varsa yazdir (cron mail/icin)
#                                  # sorun yoksa sessiz + exit 0
#   ./healthcheck.sh --only etcd  # Sadece belirli isim(ler); virgul ile liste
#                                  # (vm-disk on ek eslesir: --only vm-disk)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "${SCRIPT_DIR}/../_common.sh"

QUIET=false
ONLY=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        --quiet) QUIET=true; shift ;;
        --only)  ONLY="${2:-}"; shift 2 ;;
        -h|--help)
            echo "Kullanim: $0 [--quiet] [--only <isim[,isim...]>]"
            exit 0
            ;;
        *) log_error "Gecersiz arguman: $1"; exit 1 ;;
    esac
done

# --only filtresi: bossa hepsi; degilse virgul listesine gore (tam veya onek)
_only_match() {
    local name="$1"
    [ -z "$ONLY" ] && return 0
    local IFS=',' item
    for item in $ONLY; do
        item="${item// /}"
        [ -z "$item" ] && continue
        case "$name" in
            "$item"|"$item"-*) return 0 ;;
        esac
    done
    return 1
}

# isim | ritim (interval, saat) | tolerans (saat)
# interval: backup'in normal beklenti araligi; tolerans: tek gecikme payi.
# Legacy isimler (etcd/openbao) shadow donemi boyunca korunur; restic mimarisi
# per-job isimlerle yazar (etcd-daily|weekly|monthly gibi) — rol env'lerinden.
declare -A INTERVAL_H=(
    [etcd]=4
    [etcd-daily]=4
    [etcd-weekly]=168
    [etcd-monthly]=720
    [openbao]=24
    [openbao-daily]=24
    [openbao-weekly]=168
    [openbao-monthly]=720
)
declare -A TOLERANCE_H=(
    [etcd]=2
    [etcd-daily]=2
    [etcd-weekly]=48
    [etcd-monthly]=168
    [openbao]=2
    [openbao-daily]=2
    [openbao-weekly]=48
    [openbao-monthly]=168
)

# Haftalik vzdump (Pazar 03:00): 168s ritim + ~2s tolerans
VM_DISK_INTERVAL_H=168
VM_DISK_TOLERANCE_H=2

PROBLEM=false

check_name() {
    local name="$1" interval="$2" tol="$3"
    local age limit

    if ! _only_match "$name"; then
        return 0
    fi

    age="$(backup_age_hours "$name" 2>/dev/null || true)"
    limit=$(( interval + tol ))

    if [ -z "$age" ]; then
        echo "[SORUN] $name — hic basarili backup kaydi yok (ritim ${interval}s + tol ${tol}s)"
        PROBLEM=true
        return 0
    fi

    if is_overdue "$name" "$interval" "$tol"; then
        echo "[SORUN] $name — son basarili backup ${age} saat once (ritim ${interval}s + tol ${tol}s = ${limit}s esik)"
        PROBLEM=true
    elif [ "$QUIET" = false ]; then
        echo "[OK]    $name — ${age} saat once (esik ${limit}s)"
    fi
}

for name in "${!INTERVAL_H[@]}"; do
    check_name "$name" "${INTERVAL_H[$name]}" "${TOLERANCE_H[$name]}"
done

# vm-disk-<ID> kayitlari (dinamik — .state altinda gorulen her full yedek)
VM_DISK_FOUND=false
shopt -s nullglob
for state_file in "${BACKUP_STATE_DIR}"/vm-disk-*.last-success; do
    check_name "$(basename "$state_file" .last-success)" "$VM_DISK_INTERVAL_H" "$VM_DISK_TOLERANCE_H"
    VM_DISK_FOUND=true
done
shopt -u nullglob

# vm-disk filtredeyse ve hic state yoksa raporla; --only disindaysa sessiz atla
if _only_match "vm-disk"; then
    if [ "$VM_DISK_FOUND" = false ]; then
        echo "[SORUN] vm-disk — hic basarili backup-full kaydi yok"
        PROBLEM=true
    fi
fi

if [ "$PROBLEM" = true ]; then
    exit 1
fi
if [ "$QUIET" = false ]; then
    log_ok "Tum backup'lar guncel"
fi
exit 0
