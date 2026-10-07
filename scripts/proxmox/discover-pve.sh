#!/bin/bash
# Proxmox ag ve altyapi bilgilerini kesfeder, yerel dosyaya yazar.
# Kullanim: ./scripts/proxmox/discover-pve.sh <PVE_IP>
# Ornek:   ./scripts/proxmox/discover-pve.sh 164.102.98.152

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PVE_IP="${1:-}"
if [ -z "$PVE_IP" ]; then
  echo "Kullanim: $0 <PVE_IP>"
  exit 1
fi

OUTPUT="$SCRIPT_DIR/pve-discovered.txt"

echo "[*] Proxmox $PVE_IP kesfediliyor..."

# SSH ile baglan, discovery scriptini calistir, ciktiyi yerel dosyaya yaz
ssh "root@$PVE_IP" bash -s > "$OUTPUT" << 'REMOTE'
#!/bin/sh

NODE=$(hostname -s 2>/dev/null || hostname)

echo "# Proxmox VE - Kesif Bilgileri"
echo "# Tarih: $(date '+%Y-%m-%d %H:%M')"
echo "# Node: $NODE"
echo ""

echo "# pve_version: $(pveversion 2>/dev/null | head -1)"

echo ""
echo "##### TEMEL BILGILER #####"

echo "target_node = \"$NODE\""

GW=$(ip route | awk '/default/{print $3; exit}')
echo "gateway = \"$GW\""

BRIDGE=$(ip -4 addr show | awk '/master/{gsub(/.*master /,""); gsub(/ .*/,""); print; exit}')
if [ -z "$BRIDGE" ]; then
  BRIDGE=$(awk '/^iface vmbr/{print $2; exit}' /etc/network/interfaces 2>/dev/null)
fi
echo "bridge = \"$BRIDGE\""

BRIDGE_INFO=$(ip -4 addr show "$BRIDGE" 2>/dev/null | awk '/inet /{print $2}' | head -1)
BRIDGE_IP=$(echo "$BRIDGE_INFO" | cut -d/ -f1)
BRIDGE_CIDR=$(echo "$BRIDGE_INFO" | cut -d/ -f2)
echo "pve_ip = \"$BRIDGE_IP\""
echo "subnet_mask = \"$BRIDGE_CIDR\""
echo "proxmox_endpoint = \"https://$BRIDGE_IP:8006\""

DNS=$(pvesh get /nodes/"$NODE"/dns --output-format json 2>/dev/null | \
  sed -n 's/.*"dns1":"\([^"]*\)".*/\1/p')
echo "dns = \"$DNS\""

echo ""
echo "##### STORAGE LISTESI #####"
echo "# storage | type | content"
pvesh get /nodes/"$NODE"/storage --output-format json 2>/dev/null | \
  sed 's/},{/\n/g' | \
  sed -n 's/.*"storage":"\([^"]*\)".*"type":"\([^"]*\)".*"content":\[\([^]]*\)\].*/\1 | \2 | \3/p'

echo ""
echo "##### VM TEMPLATELERI #####"
echo "# vmid | name | status"
qm list 2>/dev/null | awk 'NR>1 && /template/{print $1" | "$2" | "$3}'
echo "# (Bos ise henuz VM template'i olusturulmamis)"

echo ""
echo "##### MEVCUT VM/LXC LISTESI #####"
echo "# vmid | name | type | status | ip"
qm list 2>/dev/null | awk 'NR>1{print $1" | "$2" | qemu | "$3" | -"}'
pct list 2>/dev/null | awk 'NR>1{print $1" | "$2" | lxc | "$3" | -"}'

echo ""
echo "##### ALPINE CT TEMPLATE #####"
pveam available 2>/dev/null | grep -i alpine | tail -5 || \
  echo "# pveam listesi alinamadi"
REMOTE

echo "[+] Tamamlandi -> $OUTPUT"
echo "    Kullanim: Bu degerleri tofu/environments/dev/common.tfvars'a isleyin."
