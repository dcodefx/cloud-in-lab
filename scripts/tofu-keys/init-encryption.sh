#!/usr/bin/env bash
# init-encryption.sh
#
# OpenTofu state encryption key'ini olusturur.
# encryption.tofu icindeki file(".../secrets/encryption.key") bu dosyayi okur.
#
# Kullanim:
#   ./init-encryption.sh                          # Olustur
#   ./init-encryption.sh --force                  # Yeniden olustur (eski state'ler okunamaz!)
#   ./init-encryption.sh --path <dosya>           # Ozel yol

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
COMMON_DIR="$SCRIPT_DIR"
# shellcheck source=./_common.sh
source "$SCRIPT_DIR/_common.sh"


PROJECT_DIR="$(find_project_root "$SCRIPT_DIR")" || die "Proje koku bulunamadi (tofu/ dizini iceren bir ust dizin yok)"
KEY_FILE="${PROJECT_DIR}/tofu/secrets/encryption.key"
FORCE=false

while [ $# -gt 0 ]; do
    case "$1" in
        --force) FORCE=true; shift ;;
        --path) KEY_FILE="$2"; shift 2 ;;
        *) die "Kullanim: $0 [--force] [--path <dosya>]" ;;
    esac
done

if [ -f "$KEY_FILE" ] && [ "$FORCE" = false ]; then
    log "Encryption key zaten var: $KEY_FILE"
    echo "  Uzerine yazmak icin: $0 --force"
    warn "Eski key ile sifrelenmis state'ler OKUNAMAZ olur."
    exit 0
fi

if [ -f "$KEY_FILE" ] && [ "$FORCE" = true ]; then
    warn "Eski key siliniyor: $KEY_FILE"
    warn "Bu key ile sifrelenmis state'ler artik okunamaz!"
    read -r -p "  Devam et? (hayir/E): " CONFIRM
    if [[ ! "$CONFIRM" =~ ^[Ee]$ ]]; then
        log "Iptal edildi"
        exit 0
    fi
    rm -f "$KEY_FILE"
fi

mkdir -p "$(dirname "$KEY_FILE")"
openssl rand -base64 32 > "$KEY_FILE"
secure_chmod "$KEY_FILE"

ok "Encryption key olusturuldu: $KEY_FILE"
echo ""
echo "  Bu key'i YEDEKLE:"
echo "    cp $KEY_FILE ${PROJECT_DIR}/backups/"
echo ""
warn "Key kaybolursa state'ler OKUNAMAZ."
