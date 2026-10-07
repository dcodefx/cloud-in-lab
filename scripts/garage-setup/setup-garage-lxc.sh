#!/usr/bin/env bash
# setup-garage-lxc.sh
# Garage S3 LXC Kurulum Scripti
# Proxmox VE 9 - Alpine Linux LXC + GarageHQ v2.1.0
#
# NOT: Bu script PROXMOX HOST'UNDA calisir (chef.sh onu oraya kopyalayip
# calistirir). Bu yuzden scripts/garage-setup/_common.sh'i source EDEMEZ -
# kendi icinde sade/bagimsiz tutulmustur.
#
# Kullanim (Proxmox sunucusunda calistir):
#   ./setup-garage-lxc.sh <container_id> [storage] [ip_cidr] [template]
#
# ip_cidr:
#   dhcp           -> DHCP ile dinamik IP (varsayilan)
#   10.0.0.5/24    -> statik IP
#
# Env:
#   TOFU_BACKEND=true|false (varsayilan: true; chef.sh --tofu-backend ile gecer)
#     true  -> tofu state backend: opentofu-state kovasi + opentofu-key + S3_BUCKET satiri
#     false -> backup garagesi: kova yok, S3_BUCKET satiri yok, backup-key adinda canli S3 anahtari
#
# Kurulum sonrasi:
#   - Tum anahtarlar /root/garage-<ID>-credentials.txt dosyasina kaydedilir (chmod 600)
#   - Container icindeki gecici secret dosyalari SILINIR
#   - Container'a giris: pct enter <ID>

set -euo pipefail

CT_ID="${1:-200}"
STORAGE="${2:-local-lvm}"
CT_IP_MODE="${3:-dhcp}"
TEMPLATE_NAME="${4:-alpine-3.23-default_20260116_amd64.tar.xz}"
CT_HOSTNAME="garage"
CT_RAM="${GARAGE_CT_RAM:-256}"
CT_SWAP="${GARAGE_CT_SWAP:-0}"
CT_DISK="${GARAGE_CT_DISK:-2}"
CT_CORES="${GARAGE_CT_CORES:-1}"
TEMPLATE="local:vztmpl/${TEMPLATE_NAME}"
CRED_FILE="/root/garage-${CT_ID}-credentials.txt"

C_GREEN='\033[0;32m'; C_RED='\033[0;31m'; C_RESET='\033[0m'
ok()  { echo -e "${C_GREEN}✔${C_RESET} $*"; }
die() { echo -e "${C_RED}✘${C_RESET} $*" >&2; exit 1; }

# Rol: TOFU_BACKEND chef.sh'ten env ile gelir (true|false).
#   true  (varsayilan) -> tofu state backend: opentofu-state kovasi + opentofu-key + S3_BUCKET satiri
#   false -> backup garagesi: kova yok, S3_BUCKET satiri yok, backup-key adinda canli S3 anahtari
# NOT: KEY_NAME/S3_BUCKET_LINE/WITH_STATE_BUCKET asagidaki pct exec ... ash -c "..."
# cift-tirnak bloklarinda YEREL expand edilir (dosyadaki ${GARAGE_IP} pattern'i gibi);
# remote ash'e literal deger gider.
TOFU_BACKEND="${TOFU_BACKEND:-true}"
case "$TOFU_BACKEND" in true|false) ;; *) die "TOFU_BACKEND true|false olmali (gelen: $TOFU_BACKEND)" ;; esac
if [ "$TOFU_BACKEND" = true ]; then
  KEY_NAME="opentofu-key"
  S3_BUCKET_LINE="S3_BUCKET=opentofu-state"
  WITH_STATE_BUCKET="true"
else
  KEY_NAME="backup-key"
  S3_BUCKET_LINE=""
  WITH_STATE_BUCKET="false"
fi

# --- Network config ---
if [ "$CT_IP_MODE" = "dhcp" ]; then
  NET_CFG="name=eth0,bridge=vmbr0,ip=dhcp"
else
  if [[ "$CT_IP_MODE" == *"/"* ]]; then
    CT_IP_ONLY="${CT_IP_MODE%/*}"
    CT_CIDR="${CT_IP_MODE#*/}"
  else
    CT_IP_ONLY="$CT_IP_MODE"
    CT_CIDR=24
  fi
  GATEWAY=$(ip route | awk '/default/{print $3; exit}')
  NET_CFG="name=eth0,bridge=vmbr0,ip=${CT_IP_ONLY}/${CT_CIDR},gw=${GATEWAY}"
fi

echo ""
echo "=== Garage S3 LXC Kurulumu ==="
echo "Container ID: $CT_ID"
echo "Storage:      $STORAGE"
echo "IP:           $CT_IP_MODE"
echo "RAM:          ${CT_RAM}MB"
echo "Disk:         ${CT_DISK}GB"
echo "Template:     $TEMPLATE_NAME"
echo ""

# 1. Alpine LXC olustur
echo "[1/8] Alpine LXC olusturuluyor..."
pct create "$CT_ID" "$TEMPLATE" \
  --hostname "$CT_HOSTNAME" \
  --storage "$STORAGE" \
  --rootfs "$STORAGE:${CT_DISK}" \
  --memory "$CT_RAM" \
  --swap "$CT_SWAP" \
  --cores "$CT_CORES" \
  --net0 "$NET_CFG" \
  --unprivileged 1 \
  --features "keyctl=1,nesting=1" \
  --ostype alpine

# 2. Container'i baslat
echo "[2/8] Container baslatiliyor..."
pct start "$CT_ID"
sleep 3

# 3. Alpine paketlerini guncelle ve Garage kur
echo "[3/8] Garage kuruluyor..."
pct exec "$CT_ID" -- ash -c "
  apk update
  apk upgrade
  apk add garage openssl
"

# 4. Garage konfigurasyonu
echo "[4/8] Garage yapilandiriliyor..."

if [ "$CT_IP_MODE" = "dhcp" ]; then
  GARAGE_IP=$(pct exec "$CT_ID" -- ash -c "ip addr show eth0 | grep 'inet ' | awk '{print \$2}' | cut -d/ -f1")
else
  GARAGE_IP=$(echo "$CT_IP_MODE" | cut -d/ -f1)
fi
[ -n "$GARAGE_IP" ] || die "Container IP adresi tespit edilemedi"

pct exec "$CT_ID" -- ash -c "
  RPC_SECRET=\$(openssl rand -hex 32)
  ADMIN_TOKEN=\$(openssl rand -base64 32)
  METRICS_TOKEN=\$(openssl rand -base64 32)

  mkdir -p /var/lib/garage/meta /var/lib/garage/data
  chown -R garage:garage /var/lib/garage
  rm -rf /etc/garage

  cat > /etc/garage.toml << EOF
metadata_dir = \"/var/lib/garage/meta\"
data_dir = \"/var/lib/garage/data\"

replication_factor = 1

rpc_bind_addr = \"[::]:3901\"
rpc_public_addr = \"${GARAGE_IP}:3901\"
rpc_secret = \"\$RPC_SECRET\"

[s3_api]
s3_region = \"garage\"
api_bind_addr = \"[::]:3900\"

[s3_web]
bind_addr = \"[::]:3902\"
root_domain = \".web.garage\"
index = \"index.html\"

[admin]
api_bind_addr = \"[::]:3903\"
admin_token = \"\$ADMIN_TOKEN\"
metrics_token = \"\$METRICS_TOKEN\"
EOF

  cat > /tmp/garage-config-keys << KEYEOF
# === Garage S3 Credentials ===
# Container ID: $CT_ID
# Tarih: \$(date)

# --- Infrastructure ---
GARAGE_IP=${GARAGE_IP}
GARAGE_PORT=3900

# --- RPC (Node communication) ---
RPC_SECRET=\$RPC_SECRET

# --- Admin API ---
ADMIN_TOKEN=\$ADMIN_TOKEN

# --- Prometheus Metrics ---
METRICS_TOKEN=\$METRICS_TOKEN
METRICS_URL=http://${GARAGE_IP}:3903/metrics

# --- S3 API (Tofu/Client) ---
S3_ENDPOINT=http://${GARAGE_IP}:3900
S3_ACCESS_KEY=PLACEHOLDER_S3_ACCESS_KEY
S3_SECRET_KEY=PLACEHOLDER_S3_SECRET_KEY
${S3_BUCKET_LINE}
S3_REGION=garage
KEYEOF
  chmod 600 /tmp/garage-config-keys
"

# 5. Init script'i duzelt
echo "[5/8] Init script duzeltiliyor..."
pct exec "$CT_ID" -- ash -c "
  cat > /etc/init.d/garage << 'INITEOF'
#!/sbin/openrc-run

name=\"Garage\"
description=\"Lightweight S3-compatible distributed object store\"

cfgfile=\"/etc/garage.toml\"
command=\"/usr/bin/garage\"
command_args=\"-c \$cfgfile server\"
command_user=\"garage\"
command_background=false
pidfile=\"/run/garage.pid\"
output_log=\"/var/log/garage.log\"
error_log=\"/var/log/garage.log\"

required_files=\"\$cfgfile\"

depend() {
    need localmount net
    after firewall
}

start() {
    ebegin \"Starting Garage\"
    start-stop-daemon --start --background \
        --make-pidfile \
        --pidfile \"\$pidfile\" \
        --user \"\$command_user\" \
        --exec \"\$command\" -- \$command_args
    eend \$?
}

stop() {
    ebegin \"Stopping Garage\"
    start-stop-daemon --stop --pidfile \"\$pidfile\"
    eend \$?
}
INITEOF
  chmod +x /etc/init.d/garage
"

# 6. Garage'yi baslat
echo "[6/8] Garage baslatiliyor..."
pct exec "$CT_ID" -- ash -c "
  rc-update add garage default
  rc-service garage start
  sleep 3
  rc-service garage status
"

# 7. Cluster layout, bucket ve key olustur
echo "[7/8] Cluster layout, bucket ve key olusturuluyor..."
pct exec "$CT_ID" -- ash -c "
  set -e
  sleep 2

  READY=0
  for i in 1 2 3 4 5; do
    if garage node id >/dev/null 2>&1; then
      READY=1
      break
    fi
    sleep 2
  done
  if [ \"\$READY\" -ne 1 ]; then
    echo 'HATA: garage node id 5 denemede de basarisiz - Garage servisi ayakta degil olabilir' >&2
    exit 1
  fi

  NODE_ID=\$(garage node id | awk '{print \$1}' | cut -d@ -f1)
  if [ -z \"\$NODE_ID\" ]; then
    echo 'HATA: NODE_ID bos - garage node id ciktisi beklenmedik formatta' >&2
    exit 1
  fi
  echo \"Node ID: \$NODE_ID\"

  garage layout assign -z dc1 -c 10G \"\$NODE_ID\"
  garage layout apply --version 1

  if [ "${WITH_STATE_BUCKET}" = true ]; then
    garage bucket create opentofu-state
  fi

  # stdout/stderr ayri yakalanir - stderr'deki olasi uyari mesajlari
  # anahtar parse'ini bozmasin diye karistirilmiyor (2>&1 | tee yerine)
  if ! garage key create ${KEY_NAME} > /tmp/garage-s3-keys 2>/tmp/garage-s3-keys.err; then
    echo 'HATA: garage key create basarisiz' >&2
    cat /tmp/garage-s3-keys.err >&2
    exit 1
  fi
  if [ "${WITH_STATE_BUCKET}" = true ]; then
    garage bucket allow opentofu-state --key ${KEY_NAME} --read --write --owner
  fi

  S3_ACCESS_KEY=\$(grep 'Key ID' /tmp/garage-s3-keys | awk '{print \$3}')
  S3_SECRET_KEY=\$(grep 'Secret key' /tmp/garage-s3-keys | awk '{print \$3}')

  # PLACEHOLDER hala yerinde kalmis olabilir (parse basarisiz) - bunu ACIKCA
  # yakala, sessizce placeholder'li bir credential dosyasi birakma
  if [ -z \"\$S3_ACCESS_KEY\" ] || [ -z \"\$S3_SECRET_KEY\" ]; then
    echo 'HATA: S3 anahtarlari cikarilamadi (garage key create ciktisi):' >&2
    cat /tmp/garage-s3-keys >&2
    exit 1
  fi

  sed -i \"s|PLACEHOLDER_S3_ACCESS_KEY|\$S3_ACCESS_KEY|\" /tmp/garage-config-keys
  sed -i \"s|PLACEHOLDER_S3_SECRET_KEY|\$S3_SECRET_KEY|\" /tmp/garage-config-keys

  # Anahtar ciktisi disk uzerinde artik gerekli degil
  shred -u /tmp/garage-s3-keys /tmp/garage-s3-keys.err 2>/dev/null || rm -f /tmp/garage-s3-keys /tmp/garage-s3-keys.err
"

# 8. Anahtarlari Proxmox host'una kaydet, container icindeki gecici dosyayi SIL
echo ""
echo "[8/8] Anahtarlar kaydediliyor: $CRED_FILE"
pct exec "$CT_ID" -- cat /tmp/garage-config-keys > "$CRED_FILE"
chmod 600 "$CRED_FILE"

# Container icinde artik gerek yok - secret disk uzerinde birakilmasin
pct exec "$CT_ID" -- sh -c "shred -u /tmp/garage-config-keys 2>/dev/null || rm -f /tmp/garage-config-keys"

# PLACEHOLDER hala varsa (yukaridaki kontrole ragmen, savunma amacli) durdur
if grep -q PLACEHOLDER "$CRED_FILE"; then
  die "Credential dosyasinda hala PLACEHOLDER deger var: $CRED_FILE (S3 anahtar olusturma basarisiz olmus olabilir)"
fi

echo ""
echo "(Credential dosyasi $CRED_FILE icinde, icerigi guvenlik geregi burada gosterilmiyor)"

echo ""
echo "============================================"
echo "  KURULUM TAMAMLANDI"
echo "============================================"
echo ""
echo "Container'a giris:"
echo "  pct enter $CT_ID"
echo ""
echo "Container'da komut calistir:"
echo "  pct exec $CT_ID -- <komut>"
echo ""
echo "Garage durumunu kontrol et:"
echo "  pct exec $CT_ID -- garage status"
echo ""
echo "Tum anahtarlar (chmod 600): $CRED_FILE"
