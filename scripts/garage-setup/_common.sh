#!/usr/bin/env bash
# _common.sh
#
# scripts/garage-setup/ altindaki tum script'lerin source ettigi ortak kutuphane.
# Tek basina calistirilmaz.
#
# Bu dosyayi source eden her script otomatik olarak alir:
#   - Renkli log fonksiyonlari (log/ok/warn/err/die)
#   - SSH/SCP icin ortak, guvenli baglanti secenekleri (SSH_OPTS)
#   - .garage-setup.env dosyasindan (gitignore'da) kullanici-ozel ayarlar
#   - find_project_root(): tofu/ dizinini iceren proje kokunu dinamik bulur
#   - secure_chmod(): secret iceren dosyalari 600 yapar

# --- Renkler / log ---
C_RED='\033[0;31m'; C_GREEN='\033[0;32m'; C_YELLOW='\033[1;33m'; C_BLUE='\033[0;34m'; C_RESET='\033[0m'
log()  { echo -e "${C_BLUE}[*]${C_RESET} $*"; }
ok()   { echo -e "${C_GREEN}✔${C_RESET} $*"; }
warn() { echo -e "${C_YELLOW}⚠${C_RESET} $*" >&2; }
err()  { echo -e "${C_RED}✘${C_RESET} $*" >&2; }
die()  { err "$*"; exit 1; }

# --- Kullanici-ozel ayarlar (gitignore'da tutulmali) ---
# _common.sh'i source eden scriptin dizinini kullanir (COMMON_DIR disaridan set edilir)
: "${COMMON_DIR:?_common.sh: kullanmadan once COMMON_DIR degiskenini set et}"
ENV_FILE="$COMMON_DIR/.garage-setup.env"
if [ -f "$ENV_FILE" ]; then
  # shellcheck source=/dev/null
  source "$ENV_FILE"
fi

# Varsayilanlar (env dosyasinda tanimli degilse devreye girer)
: "${GARAGE_PVE_IP:=}"
: "${GARAGE_CT_ID:=300}"
: "${GARAGE_ALPINE_TEMPLATE:=alpine-3.23-default_20260116_amd64.tar.xz}"
# Garage icine SSH (kosu bazinda CLI --enable-ssh ile ezilebilir):
#   true  -> chef.sh openssh + public key kurar (backup garagelari;
#            maintenance/ansible erisimi icin gerekli)
#   false -> SSH yok; erisim yalniz pve uzerinden pct exec (tofu state
#            garagelari; default — least privilege)
: "${GARAGE_ENABLE_SSH:=false}"

# --- SSH/SCP guvenli baglanti secenekleri ---
# ControlMaster: tek parola ile tum baglantilar (chef.sh'in coklu ssh cagrisi icin onemli)
# BatchMode: parola sorulacaksa asilı kalmadan hemen basarisiz ol
# ConnectTimeout: host erisilemezse cabuk basarisiz ol
SSH_MASTER_PATH="/tmp/garage-setup-ssh-%r@%h:%p"
SSH_OPTS=(
  -o ControlMaster=auto
  -o ControlPath="$SSH_MASTER_PATH"
  -o ControlPersist=300
  -o BatchMode=yes
  -o ConnectTimeout=10
)

ssh_close_master() {
  local host="$1"
  ssh -O exit -o ControlPath="$SSH_MASTER_PATH" "root@${host}" 2>/dev/null || true
}

# --- Proje kokunu dinamik bul (tofu/ dizinini iceren en yakin ust dizin) ---
# Script'lerin scripts/ altinda hangi derinlikte oldugu degisse bile calisir.
find_project_root() {
  local dir="$1"
  local depth=0
  while [ "$depth" -lt 8 ]; do
    if [ -d "$dir/tofu" ]; then
      echo "$dir"
      return 0
    fi
    local parent
    parent="$(dirname "$dir")"
    [ "$parent" = "$dir" ] && break
    dir="$parent"
    depth=$((depth + 1))
  done
  return 1
}

# --- Secret iceren dosyalari guvenli izinle koru ---
secure_chmod() {
  local f="$1"
  [ -f "$f" ] || return 0
  chmod 600 "$f"
}

# --- PVE_IP/CT_ID zorunlulugunu dogrula ---
require_pve_ip() {
  if [ -z "${GARAGE_PVE_IP:-}" ] && [ -z "${1:-}" ]; then
    die "Proxmox host IP'si belirtilmedi. --host ile ver, ya da $COMMON_DIR/.garage-setup.env" \
        "dosyasinda GARAGE_PVE_IP=... tanimla (ornek icin garage-setup.env.example'a bak)."
  fi
}
