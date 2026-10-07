#!/usr/bin/env bash
# _common.sh
#
# script' in source ettigi ortak kutuphane.
# Tek basina calistirilmaz.
#
# Bu dosyayi source eden her script otomatik olarak alir:
#   - Renkli log fonksiyonlari (log/ok/warn/err/die)
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



