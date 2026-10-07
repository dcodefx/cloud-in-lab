#!/usr/bin/env bash
#
# setup-proxmox-token.sh
# Proxmox VE 9 - Terraform/OpenTofu icin API Token + Role + Kullanici olusturma
#
# Duzeltilen/eklenen ozellikler (onceki versiyona gore):
#   - stdout/stderr karisikligi bugu duzeltildi (token dosyasi artik bozulmuyor)
#   - Idempotent: role/user/token zaten varsa akilli sekilde atlar ya da --force ile yeniler
#   - Guvenli dosya izinleri (chmod 600) hem yerel hem host tarafinda
#   - Realm varsayilani @pve (otomasyon hesaplari icin @pam yerine daha dogru secim)
#   - PVE9 icin guncel yetki listesi (Pool.Allocate, Sys.Console, Sys.Modify, SDN.Use eklendi)
#   - jq varsa onunla, yoksa sed fallback ile JSON parse
#   - Tum degerler CLI flag ile parametrik
#
# Kullanim:
#   ./setup-proxmox-token.sh --host 164.102.98.152
#   ./setup-proxmox-token.sh --host 164.102.98.152 --user terraform-prov --realm pve --force
#
# Tum secenekler icin: ./setup-proxmox-token.sh --help

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ----------------------------------------------------------------------------
# Varsayilanlar
# ----------------------------------------------------------------------------
PVE_HOST=""
PVE_USERNAME="terraform-prov"
REALM="pve"                 # pve | pam  (otomasyon hesabi icin pve onerilir)
TOKEN_ID="terraform"
ROLE_NAME="TerraformProv"
OUTPUT_FILE="$SCRIPT_DIR/pve-token.txt"
FORCE=false
SKIP_BACKUP=false           # host uzerinde /root/pve-credentials.txt yedegini olusturma

# PVE9 icin guncel, bpg/proxmox ve Telmate provider dokumantasyonuyla dogrulanmis liste
DEFAULT_PRIVS="Datastore.AllocateSpace Datastore.AllocateTemplate Datastore.Audit \
Pool.Allocate Pool.Audit \
Sys.Audit Sys.Console Sys.Modify \
VM.Allocate VM.Audit VM.Clone \
VM.Config.CDROM VM.Config.Cloudinit VM.Config.CPU VM.Config.Disk \
VM.Config.HWType VM.Config.Memory VM.Config.Network VM.Config.Options \
VM.Migrate VM.PowerMgmt VM.GuestAgent.Audit \
SDN.Use"
PRIVS="$DEFAULT_PRIVS"
ACL_PATH="/"

# ----------------------------------------------------------------------------
# Loglama
# ----------------------------------------------------------------------------
C_GREEN='\033[0;32m'; C_YELLOW='\033[1;33m'; C_RED='\033[0;31m'; C_BLUE='\033[0;34m'; C_RESET='\033[0m'
log()  { echo -e "${C_BLUE}[*]${C_RESET} $*"; }
ok()   { echo -e "${C_GREEN}✔${C_RESET} $*"; }
warn() { echo -e "${C_YELLOW}⚠${C_RESET} $*" >&2; }
err()  { echo -e "${C_RED}✘${C_RESET} $*" >&2; }
die()  { err "$*"; exit 1; }

usage() {
  cat << 'EOF'
Kullanim: setup-proxmox-token.sh --host <PVE_IP> [secenekler]

Zorunlu:
  --host <ip>            Proxmox host adresi (SSH ile root erisimi olmali)

Opsiyonel:
  --user <ad>             (varsayilan: terraform-prov)
  --realm <pve|pam>        (varsayilan: pve - otomasyon hesaplari icin onerilir)
  --token-id <ad>          (varsayilan: terraform)
  --role <ad>              (varsayilan: TerraformProv)
  --privs "<liste>"        Ozel yetki listesi (varsayilan: PVE9 icin guncel liste)
  --acl-path <path>        ACL kapsamı (varsayilan: / - tum cluster)
  --output <dosya>         Yerel cikti dosyasi (varsayilan: ./pve-token.txt)
  --force                  Role/user/token zaten varsa siler ve yeniden olusturur
  --skip-backup            Host uzerinde /root/pve-credentials.txt yedegi olusturma
  -h, --help                Bu yardimi goster

ONEMLI: --force ile token yenilenirse ESKI TOKEN GECERSIZ OLUR - onu kullanan
tum sistemleri (OpenTofu/Terraform config'leri) guncellemen gerekir.
EOF
}

# ----------------------------------------------------------------------------
# Argumanlari parse et
# ----------------------------------------------------------------------------
while [ $# -gt 0 ]; do
  case "$1" in
    --host) PVE_HOST="$2"; shift 2 ;;
    --user) PVE_USERNAME="$2"; shift 2 ;;
    --realm) REALM="$2"; shift 2 ;;
    --token-id) TOKEN_ID="$2"; shift 2 ;;
    --role) ROLE_NAME="$2"; shift 2 ;;
    --privs) PRIVS="$2"; shift 2 ;;
    --acl-path) ACL_PATH="$2"; shift 2 ;;
    --output) OUTPUT_FILE="$2"; shift 2 ;;
    --force) FORCE=true; shift ;;
    --skip-backup) SKIP_BACKUP=true; shift ;;
    -h|--help) usage; exit 0 ;;
    *) die "Bilinmeyen secenek: $1 (--help ile kullanim)" ;;
  esac
done

[ -n "$PVE_HOST" ] || { usage; die "--host zorunlu"; }
[ "$REALM" = "pve" ] || [ "$REALM" = "pam" ] || die "--realm 'pve' ya da 'pam' olmali"
PVE_USER="${PVE_USERNAME}@${REALM}"

if [ "$REALM" = "pam" ]; then
  warn "@pam realm secildi: bu, host uzerinde '$PVE_USERNAME' adinda gercek bir Linux"
  warn "kullanicisinin var olmasini VARSAYAR (parola login icin). Sadece API token"
  warn "kullanacaksan '@pve' realm (varsayilan) daha uygundur."
fi

log "Plan: user=$PVE_USER role=$ROLE_NAME token-id=$TOKEN_ID acl-path=$ACL_PATH force=$FORCE"

# ----------------------------------------------------------------------------
# Remote script
# ----------------------------------------------------------------------------
REMOTE_ARGS=(
  "$PVE_USER" "$TOKEN_ID" "$ROLE_NAME" "$PRIVS" "$ACL_PATH" "$FORCE" "$SKIP_BACKUP"
)

REMOTE_CMD="bash -s --"
for _arg in "${REMOTE_ARGS[@]}"; do
  REMOTE_CMD+=" $(printf '%q' "$_arg")"
done

log "Proxmox host'a baglaniliyor: $PVE_HOST"
# -o BatchMode=yes: parola sorulacaksa script asilı kalmadan hemen hata versin
# -o ConnectTimeout=10: host erisilemezse cabuk basarisiz olsun
TOKEN_LINE="$(ssh -o BatchMode=yes -o ConnectTimeout=10 "root@${PVE_HOST}" "$REMOTE_CMD" << 'REMOTE'
set -euo pipefail

PVE_USER="$1"; TOKEN_ID="$2"; ROLE_NAME="$3"; PRIVS="$4"; ACL_PATH="$5"; FORCE="$6"; SKIP_BACKUP="$7"
BACKUP_FILE="/root/pve-credentials.txt"

C_GREEN='\033[0;32m'; C_YELLOW='\033[1;33m'; C_RED='\033[0;31m'; C_RESET='\033[0m'
# NOT: Bu fonksiyonlar KASITLI olarak >&2 kullanir - script'in gercek stdout'u
# SADECE en sondaki tek "proxmox_token = ..." satirina ayrilmis, yerel tarafta
# dosyaya yaziliyor. Herhangi bir durum/hata mesaji stdout'a karisirsa dosya
# bozulur - onceki versiyondaki bug tam olarak buydu.
say()  { echo -e "$*" >&2; }
sayok(){ echo -e "${C_GREEN}✔${C_RESET} $*" >&2; }
saywarn(){ echo -e "${C_YELLOW}⚠${C_RESET} $*" >&2; }
sayerr(){ echo -e "${C_RED}✘${C_RESET} $*" >&2; }

say "=== Proxmox Terraform Token Kurulumu ==="
say "Kullanici: $PVE_USER | Rol: $ROLE_NAME | Token ID: $TOKEN_ID | ACL: $ACL_PATH"
say ""

# --- 1) Role ---
if pveum role list --output-format json 2>/dev/null | grep -q "\"roleid\":\"${ROLE_NAME}\"" ; then
  if [ "$FORCE" = "true" ]; then
    say "[1/4] Rol '$ROLE_NAME' mevcut, --force ile guncelleniyor..."
    pveum role modify "$ROLE_NAME" -privs "$PRIVS" >&2
  else
    say "[1/4] Rol '$ROLE_NAME' zaten mevcut, atlaniyor (yetkileri guncellemek icin --force kullan)"
  fi
else
  say "[1/4] Rol olusturuluyor: $ROLE_NAME"
  pveum role add "$ROLE_NAME" -privs "$PRIVS" >&2
fi
sayok "Rol hazir"

# --- 2) Kullanici ---
if pveum user list --output-format json 2>/dev/null | grep -q "\"userid\":\"${PVE_USER}\"" ; then
  say "[2/4] Kullanici '$PVE_USER' zaten mevcut, atlaniyor"
else
  say "[2/4] Kullanici olusturuluyor: $PVE_USER"
  pveum user add "$PVE_USER" --comment "Terraform/OpenTofu automation - $(date '+%Y-%m-%d')" >&2
fi
sayok "Kullanici hazir"

# --- 3) ACL ---
say "[3/4] ACL ataniyor: $PVE_USER -> $ROLE_NAME ($ACL_PATH)"
pveum acl modify "$ACL_PATH" -user "$PVE_USER" -role "$ROLE_NAME" >&2
sayok "ACL atandi"

# --- 4) Token ---
TOKEN_EXISTS=false
if pveum user token list "$PVE_USER" --output-format json 2>/dev/null | grep -q "\"tokenid\":\"${TOKEN_ID}\""; then
  TOKEN_EXISTS=true
fi

if [ "$TOKEN_EXISTS" = "true" ] && [ "$FORCE" != "true" ]; then
  sayerr "Token '$PVE_USER!$TOKEN_ID' zaten mevcut."
  sayerr "Proxmox guvenlik geregi secret'i tekrar GOSTEREMEZ - yenilemek icin --force kullan"
  sayerr "(--force ESKI TOKEN'I GECERSIZ KILAR, onu kullanan sistemleri guncellemen gerekir)"
  exit 1
fi

if [ "$TOKEN_EXISTS" = "true" ] && [ "$FORCE" = "true" ]; then
  say "[4/4] Token '$TOKEN_ID' mevcut, --force ile siliniyor ve yeniden olusturuluyor..."
  pveum user token remove "$PVE_USER" "$TOKEN_ID" >&2
else
  say "[4/4] Token olusturuluyor: $PVE_USER!$TOKEN_ID"
fi

TOKEN_RAW="$(pveum user token add "$PVE_USER" "$TOKEN_ID" --privsep=0 --output-format json 2>&1)" || {
  sayerr "Token olusturulamadi!"
  sayerr "$TOKEN_RAW"
  exit 1
}

# jq varsa onunla parse et (daha saglam), yoksa sed fallback
if command -v jq >/dev/null 2>&1; then
  TOKEN_VALUE="$(echo "$TOKEN_RAW" | jq -r '.value // empty' 2>/dev/null || true)"
else
  TOKEN_VALUE="$(echo "$TOKEN_RAW" | sed -n 's/.*"value"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p')"
fi

if [ -z "$TOKEN_VALUE" ]; then
  sayerr "Token JSON parse edilemedi, ham cikti:"
  sayerr "$TOKEN_RAW"
  exit 1
fi

FULL_TOKEN="${PVE_USER}!${TOKEN_ID}=${TOKEN_VALUE}"
sayok "Token olusturuldu"

# --- Host tarafi yedek (opsiyonel) ---
if [ "$SKIP_BACKUP" != "true" ]; then
  {
    echo "# Proxmox VE 9 - Terraform Token"
    echo "# Tarih: $(date '+%Y-%m-%d %H:%M')"
    echo "# Kullanici: $PVE_USER"
    echo ""
    echo "proxmox_token = \"$FULL_TOKEN\""
  } > "$BACKUP_FILE"
  chmod 600 "$BACKUP_FILE"
  sayok "Host yedegi: $BACKUP_FILE (chmod 600)"
  saywarn "Bu dosya host uzerinde duz metin secret icerir - guvenlik politikana"
  saywarn "gore islemin sonunda silmeyi (rm -f $BACKUP_FILE) degerlendir."
else
  say "  -> --skip-backup: host uzerinde yedek olusturulmadi"
fi

say ""
say "=== ISLEM TAMAMLANDI ==="

# TEK stdout satiri - yerel tarafta dosyaya yazilacak olan budur
echo "$FULL_TOKEN"
REMOTE
)"

# ----------------------------------------------------------------------------
# Yerel tarafta guvenli sekilde kaydet
# ----------------------------------------------------------------------------
[ -n "$TOKEN_LINE" ] || die "Token alinamadi (uzak script bos dondu, yukaridaki hata mesajlarina bak)"

{
  echo "# Proxmox VE 9 - Terraform/OpenTofu API Token"
  echo "# Olusturulma: $(date '+%Y-%m-%d %H:%M')"
  echo "# Host: $PVE_HOST | Kullanici: $PVE_USER | Rol: $ROLE_NAME"
  echo ""
  echo "proxmox_token = \"$TOKEN_LINE\""
} > "$OUTPUT_FILE"
chmod 600 "$OUTPUT_FILE"

ok "Tamamlandi -> $OUTPUT_FILE (chmod 600)"
echo ""
echo "Kullanim: pve-token.txt icindeki satiri"
echo "  tofu/environments/dev/common.tfvars icindeki proxmox_token alanina yazin."
echo ""
warn "Bu dosyayi ASLA git'e commit etme - .gitignore'a ekli oldugundan emin ol:"
echo "  echo 'pve-token.txt' >> .gitignore"
