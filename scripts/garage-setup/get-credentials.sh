#!/usr/bin/env bash
# get-credentials.sh
#
# Garage credential dosyasini Proxmox'tan guvenli sekilde kopyalar.
#
# Kullanim:
#   ./get-credentials.sh --host <PVE_IP> --ctid <CT_ID>
#
# Ornek:
#   ./get-credentials.sh                              # .garage-setup.env varsayilanlari
#   ./get-credentials.sh --host 164.102.98.152 --ctid 301

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
COMMON_DIR="$SCRIPT_DIR"
# shellcheck source=./_common.sh
source "$SCRIPT_DIR/_common.sh"

PVE_IP="$GARAGE_PVE_IP"
CT_ID="$GARAGE_CT_ID"

while [ $# -gt 0 ]; do
  case "$1" in
    --host) PVE_IP="$2"; shift 2 ;;
    --ctid) CT_ID="$2"; shift 2 ;;
    -h|--help) echo "Kullanim: $0 --host <PVE_IP> --ctid <CT_ID>"; exit 0 ;;
    *) die "Bilinmeyen secenek: $1" ;;
  esac
done

require_pve_ip "$PVE_IP"

REMOTE_FILE="/root/garage-${CT_ID}-credentials.txt"
LOCAL_FILE="$SCRIPT_DIR/garage-${CT_ID}-credentials.txt"

log "Credential dosyasi kopyalaniyor: root@${PVE_IP}:${REMOTE_FILE}"

# scp basarisiz olursa (dosya yok, izin sorunu, ag kopmasi) set -e script'i
# durdurur - onceki versiyon bunu kontrol etmiyordu, "basarili" mesaji
# gostererek chef.sh'in eksik dosyayla devam etmesine sebep oluyordu.
if ! scp "${SSH_OPTS[@]}" "root@${PVE_IP}:${REMOTE_FILE}" "$LOCAL_FILE"; then
  die "Credential dosyasi kopyalanamadi: root@${PVE_IP}:${REMOTE_FILE}
    Olasi sebepler:
      - Container henuz Garage kurulumunu tamamlamamis olabilir
      - CT_ID ($CT_ID) yanlis olabilir
      - Dosya host uzerinde farkli bir isimle olusmus olabilir"
fi

# Bos/yarim dosya kontrolu (scp "basarili" donup 0 byte dosya birakabilir)
if [ ! -s "$LOCAL_FILE" ]; then
  rm -f "$LOCAL_FILE"
  die "Indirilen dosya bos - kopyalama basarisiz sayiliyor"
fi

secure_chmod "$LOCAL_FILE"
ok "Kopyalandi ve korundu (chmod 600): $LOCAL_FILE"
