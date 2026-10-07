#!/usr/bin/env bash
# generate-garage-backend.sh
#
# Garage credential dosyasini okuyarak Tofu backend config dosyalarini olusturur.
#
# Kullanim:
#   ./generate-garage-backend.sh <credential_dosyasi> [secenekler]
#
# Secenekler:
#   --dry-run    Sadece goster, degistirme
#   --encrypt    Backend dosyalarini sifrele
#   --env        Ortam adi (dev/prod)
#
# Ornek:
#   ./generate-garage-backend.sh garage-300-credentials.txt
#   ./generate-garage-backend.sh garage-300-credentials.txt --dry-run
#   ./generate-garage-backend.sh garage-300-credentials.txt --encrypt --env prod

set -euo pipefail
export LC_ALL=C
shopt -s nullglob

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
COMMON_DIR="$SCRIPT_DIR"
# shellcheck source=./_common.sh
source "$SCRIPT_DIR/_common.sh"

# PROJECT_DIR'i sabit "iki dizin yukari" varsayimi yerine dinamik bul -
# script'in scripts/ altinda hangi derinlikte oldugu degisse bile calisir.
PROJECT_DIR="$(find_project_root "$SCRIPT_DIR")" || die "Proje koku bulunamadi (tofu/ dizini iceren bir ust dizin yok)"

DRY_RUN=false
ENCRYPT=false
ENV_NAME="dev"
TEMPLATE_DIR="$PROJECT_DIR/templates"
BACKEND_DIR="$PROJECT_DIR/tofu/backends"
BACKUP_DIR="$BACKEND_DIR/.backup"
CRED_FILE=""

STACKS_DIR="$PROJECT_DIR/tofu/stacks"
STACKS=()
if [ -d "$STACKS_DIR" ]; then
    for dir in "$STACKS_DIR"/*/; do
        [ -d "$dir" ] && STACKS+=("$(basename "$dir")")
    done
fi

while [ $# -gt 0 ]; do
    case "$1" in
        --dry-run) DRY_RUN=true; shift ;;
        --encrypt) ENCRYPT=true; shift ;;
        --env) ENV_NAME="$2"; shift 2 ;;
        *) [ -z "$CRED_FILE" ] && CRED_FILE="$1"; shift ;;
    esac
done

if [ -z "$CRED_FILE" ]; then
    CRED_FILES=("$SCRIPT_DIR"/garage-*-credentials.txt)   # nullglob: yoksa bos array, "ls" hackine gerek yok
    if [ ${#CRED_FILES[@]} -eq 0 ]; then
        die "Credential dosyasi bulunamadi
    Kullanim: $0 <credential_dosyasi> [--dry-run] [--encrypt] [--env dev|prod]"
    elif [ ${#CRED_FILES[@]} -eq 1 ]; then
        CRED_FILE="${CRED_FILES[0]}"
        log "Credential dosyasi bulundu: $CRED_FILE"
    else
        echo "Credential dosyalari:"
        for i in "${!CRED_FILES[@]}"; do echo "  $((i+1))) ${CRED_FILES[$i]}"; done
        read -r -p "Seciminiz [1]: " CHOICE
        CHOICE=${CHOICE:-1}
        CRED_FILE="${CRED_FILES[$((CHOICE-1))]}"
    fi
fi

[ -f "$CRED_FILE" ] || die "$CRED_FILE bulunamadi"

TEMPLATE="$TEMPLATE_DIR/garage-backend.tfbackend.template"
[ -f "$TEMPLATE" ] || die "Template bulunamadi: $TEMPLATE"

[ ${#STACKS[@]} -gt 0 ] || die "tofu/stacks altinda hic stack bulunamadi ($STACKS_DIR)"

# --- Credential dosyasini GUVENLI sekilde oku ---
# "source $CRED_FILE" yerine: dosya sadece KEY=VALUE satirlari icermeli,
# beklenmeyen bir icerik (komut enjeksiyonu) varsa CALISTIRMAK yerine yok say.
log "Credential dosyasi okunuyor: $CRED_FILE"
declare -A CREDS
while IFS='=' read -r key value; do
  # Sadece [A-Z_][A-Z0-9_]*=deger formatindaki satirlari kabul et, yorum/bos satiri atla
  [[ "$key" =~ ^[A-Z_][A-Z0-9_]*$ ]] || continue
  CREDS["$key"]="$value"
done < <(grep -E '^[A-Z_][A-Z0-9_]*=' "$CRED_FILE")

GARAGE_IP="${CREDS[GARAGE_IP]:-}"
GARAGE_PORT="${CREDS[GARAGE_PORT]:-3900}"
S3_ACCESS_KEY="${CREDS[S3_ACCESS_KEY]:-}"
S3_SECRET_KEY="${CREDS[S3_SECRET_KEY]:-}"
S3_BUCKET="${CREDS[S3_BUCKET]:-}"
S3_REGION="${CREDS[S3_REGION]:-}"

MISSING_VARS=()
for var in GARAGE_IP S3_ACCESS_KEY S3_SECRET_KEY S3_BUCKET S3_REGION; do
    [ -n "${CREDS[$var]:-}" ] || MISSING_VARS+=("$var")
done
if [ ${#MISSING_VARS[@]} -gt 0 ]; then
    die "Credential dosyasinda eksik degiskenler: ${MISSING_VARS[*]}"
fi
# S3_ACCESS_KEY setup-garage-lxc.sh tarafindan doldurulamadiysa placeholder kalmis olabilir
if [[ "$S3_ACCESS_KEY" == PLACEHOLDER_* ]] || [[ "$S3_SECRET_KEY" == PLACEHOLDER_* ]]; then
    die "Credential dosyasinda PLACEHOLDER deger var - Garage anahtar olusturma basarisiz olmus olabilir.
    setup-garage-lxc.sh'i tekrar calistirmayi dene ya da container icinde 'garage key list' ile kontrol et."
fi

if [ "$DRY_RUN" = true ]; then
    echo ""
    echo "=== DRY RUN ==="
    echo "Credential: $CRED_FILE"
    echo "Ortam: $ENV_NAME"
    echo ""
    echo "Degiskenler:"
    echo "  GARAGE_IP:      $GARAGE_IP"
    echo "  GARAGE_PORT:    $GARAGE_PORT"
    echo "  S3_ACCESS_KEY:  ${S3_ACCESS_KEY:0:12}..."
    echo "  S3_SECRET_KEY:  ${S3_SECRET_KEY:0:8}..."
    echo "  S3_BUCKET:      $S3_BUCKET"
    echo "  S3_REGION:      $S3_REGION"
    echo ""
    echo "Olusturulacak dosyalar:"
    for STACK in "${STACKS[@]}"; do echo "  $BACKEND_DIR/$STACK.backend.tfbackend"; done
    echo ""
    echo "Sifreleme: $([ "$ENCRYPT" = true ] && echo Evet || echo Hayir)"
    exit 0
fi

# --- Backup al ---
mkdir -p "$BACKUP_DIR"
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
BACKUP_COUNT=0
for f in "$BACKEND_DIR"/*.backend.tfbackend; do
    [ -f "$f" ] || continue
    cp "$f" "$BACKUP_DIR/$(basename "$f").$TIMESTAMP"
    secure_chmod "$BACKUP_DIR/$(basename "$f").$TIMESTAMP"
    BACKUP_COUNT=$((BACKUP_COUNT + 1))
done
[ "$BACKUP_COUNT" -gt 0 ] && log "Backup alindi: $BACKUP_COUNT dosya -> $BACKUP_DIR/*.$TIMESTAMP"

# --- Template'den olustur ---
echo ""
log "Backend dosyalari olusturuluyor..."
for STACK in "${STACKS[@]}"; do
    OUTPUT="$BACKEND_DIR/$STACK.backend.tfbackend"
    sed \
        -e "s|{{GARAGE_IP}}|${GARAGE_IP}|g" \
        -e "s|{{GARAGE_PORT}}|${GARAGE_PORT}|g" \
        -e "s|{{GARAGE_ACCESS_KEY}}|${S3_ACCESS_KEY}|g" \
        -e "s|{{GARAGE_SECRET_KEY}}|${S3_SECRET_KEY}|g" \
        -e "s|{{GARAGE_BUCKET}}|${S3_BUCKET}|g" \
        -e "s|{{GARAGE_REGION}}|${S3_REGION}|g" \
        -e "s|{{STACK}}|${STACK}|g" \
        "$TEMPLATE" > "$OUTPUT"
    secure_chmod "$OUTPUT"   # S3 secret key iceriyor - chmod 600 sart
    ok "Olusturuldu: $STACK.backend.tfbackend"
done

# --- Sifreleme ---
if [ "$ENCRYPT" = true ]; then
    ENCRYPT_KEY_FILE="$PROJECT_DIR/tofu/secrets/encryption.key"
    [ -f "$ENCRYPT_KEY_FILE" ] || die "Encryption key bulunamadi: $ENCRYPT_KEY_FILE
    Once calistir: scripts/tofu-keys/init-encryption.sh"

    echo ""
    log "Backend dosyalari sifreleniyor..."
    for f in "$BACKEND_DIR"/*.backend.tfbackend; do
        [ -f "$f" ] || continue
        openssl enc -aes-256-cbc -salt -pbkdf2 \
            -in "$f" -out "$f.enc" -pass "file:$ENCRYPT_KEY_FILE" 2>/dev/null
        mv "$f.enc" "$f"
        secure_chmod "$f"
        ok "Sifrelendi: $(basename "$f")"
    done
fi

echo ""
echo "=== Tamamlandi ==="
echo ""
echo "Backend dosyalari guncellendi:"
for STACK in "${STACKS[@]}"; do echo "  $BACKEND_DIR/$STACK.backend.tfbackend"; done
echo ""
echo "Sonraki adim:"
echo "  cd tofu/stacks/k8s-cluster"
echo "  tofu init -backend-config=../../backends/k8s-cluster.backend.tfbackend"
echo "  tofu validate"
echo "  tofu plan"
echo "  tofu apply"
