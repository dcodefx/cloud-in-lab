#!/usr/bin/env bash
#
# create-vm-template.sh
# Proxmox VE 8/9 - Cloud-Image tabanli VM Template olusturma
#
# Ozellikler:
#   - Dinamik dagitim/versiyon cozumleme (Ubuntu/Debian/Rocky/AlmaLinux icin gomulu,
#     digerleri icin --image-url ile evrensel destek)
#   - Storage-agnostik disk import (LVM/ZFS/dir/NFS hepsinde calisir)
#   - qemu-guest-agent kurulumu host'a paket bulastirmadan, cloud-init ile first-boot'ta
#   - Otomatik/serbest VM ID atama (pvesh nextid)
#   - Checksum dogrulama (best-effort, Ubuntu/Debian icin otomatik)
#   - UEFI/BIOS, custom CPU tipi, disk boyutu, bridge/VLAN, static IP destegi
#   - --dry-run, --force, --list-distros
#
# Kullanim:
#   ./create-vm-template.sh --host 164.102.98.152 --distro ubuntu --version 24.04
#   ./create-vm-template.sh --host 164.102.98.152 --distro rocky --version 9 --storage local-zfs
#   ./create-vm-template.sh --host 164.102.98.152 --image-url https://.../custom.qcow2 \
#       --os-family debian --name my-custom-template
#
# Tum secenekler icin: ./create-vm-template.sh --help

set -euo pipefail

# ----------------------------------------------------------------------------
# Varsayilanlar
# ----------------------------------------------------------------------------
PVE_HOST=""
DISTRO="ubuntu"
VERSION=""
VM_ID=""              # bos birakilirsa pvesh ile otomatik atanir
VM_NAME=""            # bos birakilirsa <distro>-<version>-template
STORAGE="local-lvm"
BRIDGE="vmbr0"
VLAN=""
CORES=2
MEMORY=2048
DISK_SIZE=""          # bos = cloud image'in kendi boyutu (orn: 20G verilirse buyutulur)
CPU_TYPE="host"
BIOS_TYPE="seabios"   # seabios | ovmf
MACHINE_TYPE=""       # bos = otomatik (ovmf icin q35 zorunlu)
CIUSER=""
SSH_PUBKEY_FILE=""
NAMESERVER=""
SEARCHDOMAIN=""
IMAGE_URL_OVERRIDE=""
OS_FAMILY_OVERRIDE=""   # debian | rhel | arch | suse
USE_VIRT_CUSTOMIZE=false
FORCE=false
DRY_RUN=false
KEEP_IMAGE=false
STRICT_CHECKSUM=false

SCRIPT_NAME="$(basename "$0")"

# ----------------------------------------------------------------------------
# Loglama
# ----------------------------------------------------------------------------
C_RESET='\033[0m'; C_BLUE='\033[0;34m'; C_GREEN='\033[0;32m'; C_YELLOW='\033[1;33m'; C_RED='\033[0;31m'
ts() { date '+%H:%M:%S'; }
log()   { echo -e "${C_BLUE}[$(ts)]${C_RESET} $*"; }
ok()    { echo -e "${C_GREEN}[$(ts)] ✔${C_RESET} $*"; }
warn()  { echo -e "${C_YELLOW}[$(ts)] ⚠${C_RESET} $*" >&2; }
err()   { echo -e "${C_RED}[$(ts)] ✘${C_RESET} $*" >&2; }
die()   { err "$*"; exit 1; }

# ----------------------------------------------------------------------------
# Yardim
# ----------------------------------------------------------------------------
usage() {
  cat << 'EOF'
Kullanim: create-vm-template.sh --host <PVE_IP> [secenekler]

Zorunlu:
  --host <ip>                Proxmox host adresi (SSH ile root erisimi olmali)

Dagitim secimi (biri):
  --distro <ad>               ubuntu | debian | rocky | almalinux  (varsayilan: ubuntu)
  --version <sürüm>            orn: 24.04 (ubuntu), 13 (debian), 9 (rocky/alma)
  --image-url <url>            Herhangi bir cloud image URL'i (yukaridakini gecersiz kilar)
  --os-family <aile>           image-url ile birlikte: debian|rhel|arch|suse
                                (qemu-guest-agent kurulum komutunu belirler)

VM ayarlari:
  --vmid <id>                 Bos birakilirsa otomatik atanir (pvesh nextid)
  --name <ad>                 Template adi (varsayilan: <distro>-<version>-template)
  --storage <ad>               (varsayilan: local-lvm)
  --bridge <ad>                 (varsayilan: vmbr0)
  --vlan <tag>
  --cores <n>                   (varsayilan: 2)
  --memory <MB>                 (varsayilan: 2048)
  --disk-size <boyut>          orn: 20G - cloud image'i bu boyuta buyutur
  --cpu-type <tip>              (varsayilan: host)
  --bios <seabios|ovmf>         (varsayilan: seabios)

Cloud-init:
  --ciuser <kullanici>
  --ssh-pubkey-file <yol>      Yerel makinedeki public key dosyasi
  --nameserver <ip>
  --searchdomain <domain>

Diger:
  --use-virt-customize        qemu-guest-agent'i cloud-init yerine imaja gomer
                               (libguestfs-tools host'a kurulur)
  --force                     Ayni VM ID zaten varsa once siler
  --keep-image                Islem sonunda indirilen imajı silme
  --strict-checksum           Checksum dogrulanamazsa/eslesmizse dur
  --dry-run                   Hicbir sey yapmadan planı goster
  --list-distros              Gomulu dagitim/versiyon eslesmelerini goster
  -h, --help                  Bu yardimi goster
EOF
}

# ----------------------------------------------------------------------------
# Gomulu dagitim cozumleme
# ----------------------------------------------------------------------------
ubuntu_codename() {
  case "$1" in
    20.04) echo "focal" ;;
    22.04) echo "jammy" ;;
    24.04) echo "noble" ;;
    24.10) echo "oracular" ;;
    25.04) echo "plucky" ;;
    25.10) echo "questing" ;;
    26.04) echo "resolute" ;;
    *) die "Bilinmeyen Ubuntu versiyonu: $1 (--image-url ile manuel URL verebilirsin)" ;;
  esac
}

debian_codename() {
  case "$1" in
    11) echo "bullseye" ;;
    12) echo "bookworm" ;;
    13) echo "trixie" ;;
    *) die "Bilinmeyen Debian versiyonu: $1 (--image-url ile manuel URL verebilirsin)" ;;
  esac
}

list_distros() {
  cat << 'EOF'
Gomulu dagitimlar (versiyon belirtilmezse varsayilan kullanilir):

  ubuntu       versiyonlar: 20.04, 22.04, 24.04*, 24.10, 25.04, 25.10, 26.04
  debian       versiyonlar: 11, 12, 13*
  rocky        versiyonlar: 8, 9*        (her zaman en son point release)
  almalinux    versiyonlar: 8, 9*        (her zaman en son point release)

  * = varsayilan versiyon

Listede olmayan her sey icin:
  --image-url <url> --os-family <debian|rhel|arch|suse>
EOF
}

# resolve_distro: DISTRO ve VERSION'a gore IMG_URL, CHECKSUM_URL, OS_FAMILY, VM_NAME_PREFIX doldurur
resolve_distro() {
  if [ -n "$IMAGE_URL_OVERRIDE" ]; then
    IMG_URL="$IMAGE_URL_OVERRIDE"
    CHECKSUM_URL=""
    [ -n "$OS_FAMILY_OVERRIDE" ] || die "--image-url kullanirken --os-family zorunlu (debian|rhel|arch|suse)"
    RESOLVED_OS_FAMILY="$OS_FAMILY_OVERRIDE"
    RESOLVED_NAME_PREFIX="custom"
    RESOLVED_VERSION="custom"
    return
  fi

  case "$DISTRO" in
    ubuntu)
      RESOLVED_VERSION="${VERSION:-24.04}"
      local codename; codename="$(ubuntu_codename "$RESOLVED_VERSION")"
      IMG_URL="https://cloud-images.ubuntu.com/${codename}/current/${codename}-server-cloudimg-amd64.img"
      CHECKSUM_URL="https://cloud-images.ubuntu.com/${codename}/current/SHA256SUMS"
      RESOLVED_OS_FAMILY="debian"
      RESOLVED_NAME_PREFIX="ubuntu-${RESOLVED_VERSION}"
      ;;
    debian)
      RESOLVED_VERSION="${VERSION:-13}"
      local codename; codename="$(debian_codename "$RESOLVED_VERSION")"
      IMG_URL="https://cloud.debian.org/images/cloud/${codename}/latest/debian-${RESOLVED_VERSION}-generic-amd64.qcow2"
      CHECKSUM_URL="https://cloud.debian.org/images/cloud/${codename}/latest/SHA512SUMS"
      RESOLVED_OS_FAMILY="debian"
      RESOLVED_NAME_PREFIX="debian-${RESOLVED_VERSION}"
      ;;
    rocky)
      RESOLVED_VERSION="${VERSION:-9}"
      IMG_URL="https://dl.rockylinux.org/pub/rocky/${RESOLVED_VERSION}/images/x86_64/Rocky-${RESOLVED_VERSION}-GenericCloud-Base.latest.x86_64.qcow2"
      # Rocky, her dosya icin ayri bir .CHECKSUM degil, dizin basina TEK bir
      # "CHECKSUM" dosyasi yayinlar (icinde "SHA256 (dosya) = hash" formati)
      CHECKSUM_URL="$(dirname "$IMG_URL")/CHECKSUM"
      RESOLVED_OS_FAMILY="rhel"
      RESOLVED_NAME_PREFIX="rocky-${RESOLVED_VERSION}"
      ;;
    almalinux|alma)
      RESOLVED_VERSION="${VERSION:-9}"
      IMG_URL="https://repo.almalinux.org/almalinux/${RESOLVED_VERSION}/cloud/x86_64/images/AlmaLinux-${RESOLVED_VERSION}-GenericCloud-latest.x86_64.qcow2"
      CHECKSUM_URL="$(dirname "$IMG_URL")/CHECKSUM"
      RESOLVED_OS_FAMILY="rhel"
      RESOLVED_NAME_PREFIX="almalinux-${RESOLVED_VERSION}"
      ;;
    *)
      die "Bilinmeyen dagitim '$DISTRO'. --list-distros ile secenekleri gor, ya da --image-url kullan."
      ;;
  esac
}

# ----------------------------------------------------------------------------
# Argumanlari parse et
# ----------------------------------------------------------------------------
while [ $# -gt 0 ]; do
  case "$1" in
    --host) PVE_HOST="$2"; shift 2 ;;
    --distro) DISTRO="$2"; shift 2 ;;
    --version) VERSION="$2"; shift 2 ;;
    --image-url) IMAGE_URL_OVERRIDE="$2"; shift 2 ;;
    --os-family) OS_FAMILY_OVERRIDE="$2"; shift 2 ;;
    --vmid) VM_ID="$2"; shift 2 ;;
    --name) VM_NAME="$2"; shift 2 ;;
    --storage) STORAGE="$2"; shift 2 ;;
    --bridge) BRIDGE="$2"; shift 2 ;;
    --vlan) VLAN="$2"; shift 2 ;;
    --cores) CORES="$2"; shift 2 ;;
    --memory) MEMORY="$2"; shift 2 ;;
    --disk-size) DISK_SIZE="$2"; shift 2 ;;
    --cpu-type) CPU_TYPE="$2"; shift 2 ;;
    --bios) BIOS_TYPE="$2"; shift 2 ;;
    --ciuser) CIUSER="$2"; shift 2 ;;
    --ssh-pubkey-file) SSH_PUBKEY_FILE="$2"; shift 2 ;;
    --nameserver) NAMESERVER="$2"; shift 2 ;;
    --searchdomain) SEARCHDOMAIN="$2"; shift 2 ;;
    --use-virt-customize) USE_VIRT_CUSTOMIZE=true; shift ;;
    --force) FORCE=true; shift ;;
    --keep-image) KEEP_IMAGE=true; shift ;;
    --strict-checksum) STRICT_CHECKSUM=true; shift ;;
    --dry-run) DRY_RUN=true; shift ;;
    --list-distros) list_distros; exit 0 ;;
    -h|--help) usage; exit 0 ;;
    *) die "Bilinmeyen secenek: $1 (--help ile kullanim)" ;;
  esac
done

[ -n "$PVE_HOST" ] || { usage; die "--host zorunlu"; }
[ "$BIOS_TYPE" = "seabios" ] || [ "$BIOS_TYPE" = "ovmf" ] || die "--bios seabios ya da ovmf olmali"

resolve_distro
[ -n "$VM_NAME" ] || VM_NAME="${RESOLVED_NAME_PREFIX}-template"
[ -n "$MACHINE_TYPE" ] || { [ "$BIOS_TYPE" = "ovmf" ] && MACHINE_TYPE="q35" || MACHINE_TYPE="pc"; }

SSH_PUBKEY_CONTENT=""
if [ -n "$SSH_PUBKEY_FILE" ]; then
  [ -f "$SSH_PUBKEY_FILE" ] || die "SSH public key dosyasi bulunamadi: $SSH_PUBKEY_FILE"
  SSH_PUBKEY_CONTENT="$(cat "$SSH_PUBKEY_FILE")"
fi
SSH_PUBKEY_B64="$(printf '%s' "$SSH_PUBKEY_CONTENT" | base64 -w0 2>/dev/null || printf '%s' "$SSH_PUBKEY_CONTENT" | base64)"

# ----------------------------------------------------------------------------
# Ozet / dry-run
# ----------------------------------------------------------------------------
log "=== Plan ==="
echo "  Host:        $PVE_HOST"
echo "  Dagitim:     $DISTRO ${RESOLVED_VERSION:+($RESOLVED_VERSION)}"
echo "  Image URL:   $IMG_URL"
echo "  OS ailesi:   $RESOLVED_OS_FAMILY"
echo "  VM ID:       ${VM_ID:-<otomatik>}"
echo "  VM adi:      $VM_NAME"
echo "  Storage:     $STORAGE"
echo "  Bridge/VLAN: $BRIDGE${VLAN:+ (vlan $VLAN)}"
echo "  Cores/RAM:   $CORES / ${MEMORY}MB"
echo "  Disk boyutu: ${DISK_SIZE:-<image varsayilani>}"
echo "  CPU tipi:    $CPU_TYPE"
echo "  BIOS:        $BIOS_TYPE (machine: $MACHINE_TYPE)"
echo "  Agent metodu: $([ "$USE_VIRT_CUSTOMIZE" = true ] && echo 'virt-customize (imaja gomulur)' || echo 'cloud-init (first boot)')"

if [ "$DRY_RUN" = true ]; then
  warn "--dry-run: hicbir islem yapilmadi."
  exit 0
fi

# ----------------------------------------------------------------------------
# Remote script - Proxmox host uzerinde calisir
# ----------------------------------------------------------------------------
REMOTE_ARGS=(
  "$DISTRO" "$RESOLVED_VERSION" "$VM_ID" "$VM_NAME" "$STORAGE" "$BRIDGE" "$VLAN"
  "$CORES" "$MEMORY" "$DISK_SIZE" "$CPU_TYPE" "$BIOS_TYPE" "$MACHINE_TYPE"
  "$CIUSER" "$SSH_PUBKEY_B64" "$NAMESERVER" "$SEARCHDOMAIN"
  "$IMG_URL" "$CHECKSUM_URL" "$RESOLVED_OS_FAMILY"
  "$USE_VIRT_CUSTOMIZE" "$FORCE" "$KEEP_IMAGE" "$STRICT_CHECKSUM"
)

log "Proxmox host'a baglaniliyor: $PVE_HOST"
# NOT: ssh, komut satirindaki argumanlari boslukla birlestirip TEK bir string
# olarak uzak shell'e gonderir - bu sirada BOS STRING argumanlar sessizce
# kaybolur ve pozisyonel parametreler kayar (orn. --vlan/--nameserver gibi
# opsiyonel bos alanlar verilmediginde). Bunu onlemek icin her argumani
# printf %q ile shell-safe kacirip TEK bir komut string'i halinde gonderiyoruz.
REMOTE_CMD="bash -s --"
for _arg in "${REMOTE_ARGS[@]}"; do
  REMOTE_CMD+=" $(printf '%q' "$_arg")"
done
# shellcheck disable=SC2087
ssh "root@${PVE_HOST}" "$REMOTE_CMD" << 'REMOTE'
set -euo pipefail

DISTRO="$1"; VERSION="$2"; VM_ID="$3"; VM_NAME="$4"; STORAGE="$5"; BRIDGE="$6"; VLAN="$7"
CORES="$8"; MEMORY="$9"; DISK_SIZE="${10}"; CPU_TYPE="${11}"; BIOS_TYPE="${12}"; MACHINE_TYPE="${13}"
CIUSER="${14}"; SSH_PUBKEY_B64="${15}"; NAMESERVER="${16}"; SEARCHDOMAIN="${17}"
IMG_URL="${18}"; CHECKSUM_URL="${19}"; OS_FAMILY="${20}"
USE_VIRT_CUSTOMIZE="${21}"; FORCE="${22}"; KEEP_IMAGE="${23}"; STRICT_CHECKSUM="${24}"

C_GREEN='\033[0;32m'; C_YELLOW='\033[1;33m'; C_RED='\033[0;31m'; C_RESET='\033[0m'
log()  { echo -e "$*"; }
ok()   { echo -e "${C_GREEN}✔${C_RESET} $*"; }
warn() { echo -e "${C_YELLOW}⚠${C_RESET} $*" >&2; }
err()  { echo -e "${C_RED}✘${C_RESET} $*" >&2; }
die()  { err "$*"; exit 1; }

IMG_FILE="/tmp/vmtemplate-$$-$(basename "$IMG_URL")"
cleanup() {
  local ec=$?
  if [ "$KEEP_IMAGE" != "true" ]; then rm -f "$IMG_FILE"; fi
  if [ $ec -ne 0 ] && [ -n "${CREATED_VMID:-}" ]; then
    warn "Hata olustu, olusturulan VM $CREATED_VMID temizleniyor..."
    qm destroy "$CREATED_VMID" --purge 2>/dev/null || true
  fi
  exit $ec
}
trap cleanup EXIT

# --- VM ID coz ---
if [ -z "$VM_ID" ]; then
  VM_ID="$(pvesh get /cluster/nextid)"
  log "[*] Otomatik VM ID atandi: $VM_ID"
fi
case "$VM_ID" in
  ''|*[!0-9]*) die "Gecersiz VM ID: $VM_ID" ;;
esac

if qm status "$VM_ID" >/dev/null 2>&1; then
  if [ "$FORCE" = "true" ]; then
    warn "VM $VM_ID zaten var, --force ile siliniyor..."
    qm destroy "$VM_ID" --purge
  else
    die "VM $VM_ID zaten mevcut! (--force ile uzerine yazilabilir, ya da --vmid bos birak / farkli ver)"
  fi
fi

echo ""
echo "=== VM Template Olusturma: $VM_NAME (ID $VM_ID) ==="

log "[1/7] Cloud-image indiriliyor: $IMG_URL"
# --progress=bar:force:noscroll: SSH uzerinden calisirken wget ciktiyi TTY
# olarak algilamayip her ilerlemede yeni satir basar (dot modu); force ile
# bar modunu zorlayip \r ile tek satirda guncellenmesini sagliyoruz.
# --timeout/--tries: aginin takilmasi durumunda script'in sonsuza dek
# beklememesi icin ust sinir koyuyoruz.
wget --progress=bar:force:noscroll --timeout=60 --tries=3 -O "$IMG_FILE" "$IMG_URL"
ok "Indirildi: $IMG_FILE ($(du -h "$IMG_FILE" | cut -f1))"

# --- Checksum dogrulama (best-effort) ---
if [ -n "$CHECKSUM_URL" ]; then
  log "[*] Checksum dogrulaniyor..."
  SUMFILE="/tmp/vmtemplate-$$-sums"
  # --timeout/--tries: checksum dosyasi indirilemezse (404/yavas ag) sonsuz
  # beklemek yerine en fazla ~60sn icinde vazgecip devam etsin.
  if wget -q --timeout=20 --tries=2 -O "$SUMFILE" "$CHECKSUM_URL" 2>/dev/null; then
    BASENAME="$(basename "$IMG_URL")"
    # Iki farkli CHECKSUM formatini da destekle:
    #   duz format    : <hash>  <dosya_adi>                 (Ubuntu/Debian SHA*SUMS)
    #   GNU/BSD format: SHA256 (<dosya_adi>) = <hash>        (Rocky/AlmaLinux CHECKSUM)
    # Rocky/Alma'nin CHECKSUM dosyasinda dosya adi "N bytes" satirinda da
    # gecebiliyor (hashsiz) - once parantezli/hash satirini tercih ediyoruz,
    # bulamazsak duz formata dusuyoruz.
    # NOT: set -e + pipefail altinda grep hicbir sey bulamazsa (exit 1) tum
    # script sessizce durur - bu yuzden her arama "|| true" ile korunuyor.
    MATCH_LINE="$(grep -F "(${BASENAME})" "$SUMFILE" 2>/dev/null | head -1 || true)"
    if [ -z "$MATCH_LINE" ]; then
      MATCH_LINE="$(grep -F "$BASENAME" "$SUMFILE" 2>/dev/null | head -1 || true)"
    fi
    EXPECTED="$(printf '%s' "$MATCH_LINE" | grep -oE '[a-fA-F0-9]{64,128}' 2>/dev/null | head -1 || true)"
    if [ -n "$EXPECTED" ]; then
      ALGO="sha256sum"; [ ${#EXPECTED} -eq 128 ] && ALGO="sha512sum"
      log "  -> Yerel $ALGO hesaplaniyor ($(du -h "$IMG_FILE" | cut -f1) - bu adim CPU/disk hizina gore 5-60sn surebilir, DONMUS GIBI GORUNSE DE calisiyor)..."
      ACTUAL="$($ALGO "$IMG_FILE" | awk '{print $1}')"
      if [ "$EXPECTED" = "$ACTUAL" ]; then
        ok "Checksum eslesti ($ALGO)"
      else
        err "Checksum UYUSMUYOR! beklenen=$EXPECTED gercek=$ACTUAL"
        [ "$STRICT_CHECKSUM" = "true" ] && die "STRICT_CHECKSUM aktif, durduruluyor."
        warn "Devam ediliyor (--strict-checksum ile bu durumda durdurulabilir)"
      fi
    else
      warn "Checksum dosyasinda '$BASENAME' bulunamadi, atlaniyor"
    fi
  else
    warn "Checksum dosyasi indirilemedi (URL/ag sorunu olabilir), atlaniyor"
  fi
  rm -f "$SUMFILE"
fi

# --- qemu-guest-agent: virt-customize (imaja gom) ---
CICUSTOM_ARG=""
if [ "$USE_VIRT_CUSTOMIZE" = "true" ]; then
  log "[2/7] qemu-guest-agent imaja gomuluyor (virt-customize)..."
  if ! command -v virt-customize >/dev/null 2>&1; then
    warn "virt-customize yok, libguestfs-tools kuruluyor..."
    apt-get update -qq && apt-get install -y -qq libguestfs-tools
  fi
  virt-customize -a "$IMG_FILE" --install qemu-guest-agent --run-command 'systemctl enable qemu-guest-agent' -q
  ok "qemu-guest-agent imaja eklendi"
else
  log "[2/7] qemu-guest-agent cloud-init (first-boot) ile kurulacak"
  # Snippets destegi olan bir storage var mi kontrol et
  SNIPPET_STORAGE=""
  for s in $(pvesm status -content snippets 2>/dev/null | awk 'NR>1{print $1}'); do
    SNIPPET_STORAGE="$s"; break
  done
  if [ -n "$SNIPPET_STORAGE" ]; then
    case "$OS_FAMILY" in
      debian) AGENT_CMD="apt-get update -y && apt-get install -y qemu-guest-agent && systemctl enable --now qemu-guest-agent" ;;
      rhel)   AGENT_CMD="dnf install -y qemu-guest-agent || yum install -y qemu-guest-agent; systemctl enable --now qemu-guest-agent" ;;
      arch)   AGENT_CMD="pacman -Sy --noconfirm qemu-guest-agent && systemctl enable --now qemu-guest-agent" ;;
      suse)   AGENT_CMD="zypper --non-interactive install qemu-guest-agent && systemctl enable --now qemu-guest-agent" ;;
      *)      AGENT_CMD="echo 'os-family bilinmiyor, qemu-guest-agent elle kurulmali'" ;;
    esac
    SNIPPET_DIR="/var/lib/vz/snippets"
    [ -d "$SNIPPET_DIR" ] || SNIPPET_DIR="$(pvesm path "$SNIPPET_STORAGE" 2>/dev/null || echo /var/lib/vz)/snippets"
    mkdir -p "$SNIPPET_DIR"
    SNIPPET_FILE="${SNIPPET_DIR}/vmtemplate-${VM_ID}-agent.yaml"
    cat > "$SNIPPET_FILE" << EOFSNIP
#cloud-config
runcmd:
  - [ bash, -c, "${AGENT_CMD}" ]
EOFSNIP
    CICUSTOM_ARG="vendor=${SNIPPET_STORAGE}:snippets/$(basename "$SNIPPET_FILE")"
    ok "cloud-init snippet hazirlandi: $SNIPPET_FILE"
  else
    warn "Snippets destekli storage bulunamadi (Datacenter -> Storage -> icerik turune 'Snippets' ekle)."
    warn "qemu-guest-agent otomatik kurulmayacak; --use-virt-customize kullan ya da elle kur."
  fi
fi

log "[3/7] VM olusturuluyor..."
qm create "$VM_ID" \
  --name "$VM_NAME" \
  --memory "$MEMORY" \
  --cores "$CORES" \
  --cpu "$CPU_TYPE" \
  --net0 "virtio,bridge=${BRIDGE}${VLAN:+,tag=${VLAN}}" \
  --agent enabled=1 \
  --machine "$MACHINE_TYPE"
CREATED_VMID="$VM_ID"
ok "VM $VM_ID olusturuldu"

if [ "$BIOS_TYPE" = "ovmf" ]; then
  log "[*] UEFI (OVMF) yapilandiriliyor..."
  qm set "$VM_ID" --bios ovmf --efidisk0 "${STORAGE}:1,efitype=4m,pre-enrolled-keys=1" >/dev/null
fi

log "[4/7] Disk import ediliyor (storage: $STORAGE)..."
qm importdisk "$VM_ID" "$IMG_FILE" "$STORAGE" >/dev/null
# Storage tipinden bagimsiz: importdisk'in olusturdugu 'unused' diski otomatik bul
# NOT: grep bos sonuc donerse (exit 1) pipefail script'i sessizce oldurur,
# bu yuzden "|| true" ile koruyup asagida acik die mesajiyla durduruyoruz.
UNUSED_LINE="$(qm config "$VM_ID" | grep -E '^unused[0-9]+:' | head -1 || true)"
[ -n "$UNUSED_LINE" ] || die "Import edilen disk bulunamadi (qm config $VM_ID cikti: bos)"
UNUSED_VOLID="${UNUSED_LINE#*: }"
ok "Disk import edildi: $UNUSED_VOLID"

log "[5/7] VM yapilandiriliyor..."
SET_ARGS=(
  --scsihw virtio-scsi-pci
  --scsi0 "$UNUSED_VOLID"
  --ide2 "${STORAGE}:cloudinit"
  --boot order=scsi0
  --serial0 socket
  --vga serial0
)
[ -n "$NAMESERVER" ]   && SET_ARGS+=(--nameserver "$NAMESERVER")
[ -n "$SEARCHDOMAIN" ] && SET_ARGS+=(--searchdomain "$SEARCHDOMAIN")
[ -n "$CIUSER" ]       && SET_ARGS+=(--ciuser "$CIUSER")
[ -n "$CICUSTOM_ARG" ] && SET_ARGS+=(--cicustom "$CICUSTOM_ARG")
qm set "$VM_ID" "${SET_ARGS[@]}" >/dev/null

if [ -n "$SSH_PUBKEY_B64" ] && [ "$SSH_PUBKEY_B64" != "" ]; then
  KEYFILE="/tmp/vmtemplate-$$-sshkey.pub"
  echo "$SSH_PUBKEY_B64" | base64 -d > "$KEYFILE"
  qm set "$VM_ID" --sshkeys "$KEYFILE" >/dev/null
  rm -f "$KEYFILE"
  ok "SSH public key eklendi"
fi
ok "VM yapilandirildi"

if [ -n "$DISK_SIZE" ]; then
  log "[6/7] Disk buyutuluyor: $DISK_SIZE"
  qm resize "$VM_ID" scsi0 "$DISK_SIZE" >/dev/null
  ok "Disk boyutu ayarlandi"
else
  log "[6/7] Disk boyutu degistirilmedi (image varsayilani korunuyor)"
fi

log "[7/7] Template'e cevriliyor..."
qm template "$VM_ID"
ok "Template $VM_ID hazir!"

echo ""
echo "=== ISLEM TAMAMLANDI ==="
echo "vm_id   = $VM_ID"
echo "vm_name = $VM_NAME"
echo "storage = $STORAGE"
echo ""
echo "OpenTofu/Terraform icin bu ID'yi template_vm_id degiskenine yazabilirsin.(tofu/environments/dev/common.tfvars icindeki)"
REMOTE

ok "Islem tamamlandi."