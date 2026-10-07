#!/usr/bin/env bash
# chef.sh
#
# Garage S3 kurulumunu orkestre eder.
# Istemci makinede calisir, Proxmox'a SSH ile baglanir.
#
# Kullanim:
#   ./chef.sh [--host IP] [--ctid ID] [--template AD] [--env dev|prod] [--encrypt]
#             [--tofu-backend true|false]
#             [--cores N] [--memory MB] [--disk GB] [--storage AD]
#
# Ornek:
#   ./chef.sh                                  # .garage-setup.env'deki varsayilanlar
#   ./chef.sh --host 164.102.98.152             # Ozel host, varsayilan CT ID
#   ./chef.sh --host 164.102.98.152 --ctid 301 --encrypt --env prod
  #   ./chef.sh --host 164.102.98.16 --ctid 302 --tofu-backend false --disk 8
  #                                               # tofu-state DISI Garage (orn: yedek
  #                                               # deposu): setup role gore kova/key
  #                                               # uretmez, S3_BUCKET satiri yazilmaz,
  #                                               # node_exporter kurulur.
#                                               # Kaynaklar: cores/memory defaultta kalir
#                                               # (1 cekirdek / 256MB — CT300 kaniti:
#                                               # ayni garage tofu state + backup'larla
#                                               # 256MB'da calisiyor); yalniz disk buyutulur.
#
# Ilk kullanimdan once:
#   cp garage-setup.env.example .garage-setup.env
#   # icindeki GARAGE_PVE_IP'yi kendi Proxmox host'una gore duzenle

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
COMMON_DIR="$SCRIPT_DIR"
# shellcheck source=./_common.sh
source "$SCRIPT_DIR/_common.sh"

TEMPLATE="$GARAGE_ALPINE_TEMPLATE"
PVE_IP="$GARAGE_PVE_IP"
CT_ID="$GARAGE_CT_ID"
ENCRYPT=false
ENV_NAME="dev"
# Kaynak varsayilanlari — create-vm-template.sh pattern'i: default'lu, CLI ile setlenebilir.
# setup-garage-lxc.sh ayni degerleri GARAGE_CT_* env'lerinden okur; chef.sh ssh uzerinden
# iletir. Not: CPU_TYPE LXC'de yoktur (QEMU VM kavrami; LXC host CPU'yu paylaşir).
TOFU_BACKEND=true
CT_CORES=1
CT_MEMORY=256
CT_DISK=2
CT_STORAGE="local-lvm"

usage() {
  cat << 'EOF'
Kullanim: chef.sh [secenekler]

  --host <ip>              Proxmox host adresi (varsayilan: .garage-setup.env)
  --ctid <id>              Garage LXC container ID (varsayilan: .garage-setup.env)
  --template <ad>          Alpine LXC template adi
  --tofu-backend <true|false>
                            Bu Garage tofu state backend'i midir? (varsayilan: true)
                            false → setup role gore (TOFU_BACKEND=false) kova/key
                            uretmez, S3_BUCKET satiri yazilmaz; node_exporter kurulur
                            (canlilik scrape).
  --cores <n>              CT cekirdek sayisi (varsayilan: 1)
  --memory <MB>            CT RAM MB (varsayilan: 256)
  --disk <GB>              CT rootfs GB (varsayilan: 2)
  --storage <ad>           PVE storage (varsayilan: local-lvm)
  --enable-ssh <true|false>
                           Garage icine SSH kurulsun mu? (varsayilan: false)
                           true -> openssh + public key (backup garagelari,
                           maintenance/ansible erisimi icin gerekli).
                           false -> SSH yok; erisim yalniz pve uzerinden
                           pct exec (tofu state garagelari).
                           .garage-setup.env GARAGE_ENABLE_SSH degeri
                           verilmemisse bu gecerlidir; verilmisse ezer.
  --encrypt                Uretilen tofu backend dosyalarini sifrele
                           (yalniz --tofu-backend=true'da anlamlidir)
  --env <dev|prod>         Backend ortam etiketi (varsayilan: dev)
                           (yalniz --tofu-backend=true'da anlamlidir)
  -h, --help               Bu yardimi goster

Env (.garage-setup.env):
  GARAGE_ENABLE_SSH=true|false
                           Garage2 icine SSH kursun mu? (varsayilan: false)
                           true -> openssh + public key eklenir; maintenance
                           (ansible [garage-backup]) bunu gerektirir.
                           false -> eski davranis: sadece pve uzerinden pct exec.
                           CLI --enable-ssh bu degeri kosu bazinda ezer.
  GARAGE_SSH_PUB_KEY=<path>
                           Kullanilacak public key (varsayilan: ~/.ssh/id_ed25519.pub;
                           maintenance.ini garage2 satiri ayni anahtari kullanir)
EOF
}

while [ $# -gt 0 ]; do
  case "$1" in
    --host) PVE_IP="$2"; shift 2 ;;
    --ctid) CT_ID="$2"; shift 2 ;;
    --template) TEMPLATE="$2"; shift 2 ;;
    --tofu-backend)
      TOFU_BACKEND="$(echo "${2:-}" | tr '[:upper:]' '[:lower:]')"
      case "$TOFU_BACKEND" in
        true|false) ;;
        *) die "--tofu-backend yalniz true|false alir (gelen: ${2:-bos})" ;;
      esac
      shift 2 ;;
    --cores) CT_CORES="$2"; shift 2 ;;
    --memory) CT_MEMORY="$2"; shift 2 ;;
    --disk) CT_DISK="$2"; shift 2 ;;
    --storage) CT_STORAGE="$2"; shift 2 ;;
    --enable-ssh)
      GARAGE_ENABLE_SSH="$(echo "${2:-}" | tr '[:upper:]' '[:lower:]')"
      case "$GARAGE_ENABLE_SSH" in
        true|false) ;;
        *) die "--enable-ssh yalniz true|false alir (gelen: ${2:-bos})" ;;
      esac
      shift 2 ;;
    --encrypt) ENCRYPT=true; shift ;;
    --env) ENV_NAME="$2"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) die "Bilinmeyen secenek: $1 (--help ile kullanim)" ;;
  esac
done

require_pve_ip "$PVE_IP"

case "$GARAGE_ENABLE_SSH" in
  true|false) ;;
  *) die "GARAGE_ENABLE_SSH yalniz true|false alir (gelen: ${GARAGE_ENABLE_SSH})" ;;
esac

# --- SSH temizligi (hata olsa bile) ---
trap 'ssh_close_master "$PVE_IP"' EXIT

echo ""
echo -e "${C_BLUE}========================================${C_RESET}"
echo -e "${C_BLUE}   Garage S3 Kurulum Sefi${C_RESET}"
echo -e "${C_BLUE}========================================${C_RESET}"
echo ""
echo "Proxmox IP:    $PVE_IP"
echo "Container ID:  $CT_ID"
echo "Sifreleme:     $([ "$ENCRYPT" = true ] && echo evet || echo hayir)"
echo "Ortam:         $ENV_NAME"
echo "Tofu backend:  $TOFU_BACKEND"
echo "SSH (garage2): $GARAGE_ENABLE_SSH"
echo "Kaynaklar:     $CT_CORES cekirdek / ${CT_MEMORY}MB RAM / ${CT_DISK}GB disk / $CT_STORAGE"
echo ""

# --- 1. SSH baglantisini kontrol et ---
log "1/10: SSH baglantisi kontrol ediliyor..."
if ! ssh "${SSH_OPTS[@]}" "root@${PVE_IP}" "echo ok" >/dev/null 2>&1; then
    die "SSH baglantisi kurulamadi: $PVE_IP
    Kontrol et:
      - IP adresi dogru mu? (.garage-setup.env)
      - SSH key tanimli mi? (BatchMode aktif, parola sormaz)
      - Root erisimi acik mi?"
fi
ok "SSH baglantisi basarili"

# --- 2. Template kontrolu ---
log "2/10: Alpine template kontrol ediliyor..."
TEMPLATE_EXISTS=$(ssh "${SSH_OPTS[@]}" "root@${PVE_IP}" "pveam list local 2>/dev/null | grep -c '$TEMPLATE'" | tr -d '[:space:]' || echo 0)
if [ "$TEMPLATE_EXISTS" -eq 0 ]; then
    log "Template bulunamadi, indiriliyor..."
    ssh "${SSH_OPTS[@]}" "root@${PVE_IP}" "pveam update && pveam download local $TEMPLATE"
    ok "Template indirildi"
else
    ok "Template mevcut"
fi

# --- 3. Container ID kontrolu ---
log "3/10: Container ID kontrol ediliyor..."
USED_IDS=$(ssh "${SSH_OPTS[@]}" "root@${PVE_IP}" "pct list 2>/dev/null | awk 'NR>1 {print \$1}'" || echo "")

CT_EXISTS=false
SKIP_SETUP=false
SKIP_CREDENTIALS=false
SELECTED_IP=""
CT_CIDR=""
if echo "$USED_IDS" | grep -q "^${CT_ID}$"; then
    CT_EXISTS=true
fi

if [ "$CT_EXISTS" = true ]; then
    log "CT $CT_ID zaten mevcut"
    echo ""
    echo "  Ne yapmak istiyorsun?"
    echo ""
    echo "  1) Mevcut CT'yi kullan (sadece credential/backend guncelle)"
    echo "  2) Yeni ID ile olustur (eskiyi silmeden)"
    echo "  3) Eski CT'yi sil, yenisini olustur"
    echo ""
    read -r -p "  Secimin [1]: " ID_CHOICE
    ID_CHOICE=${ID_CHOICE:-1}

    case $ID_CHOICE in
        1)
            log "Mevcut CT $CT_ID kullaniliyor"
            SKIP_SETUP=true
            CT_IP_CFG=$(ssh "${SSH_OPTS[@]}" "root@${PVE_IP}" "pct config $CT_ID 2>/dev/null | grep -oP 'ip=\K[0-9.]+(/[0-9]+)?'" || echo "")
            if [ -n "$CT_IP_CFG" ] && [[ "$CT_IP_CFG" != "dhcp" ]]; then
                SELECTED_IP="${CT_IP_CFG%%/*}"
                CT_CIDR="${CT_IP_CFG##*/}"
                [[ "$CT_CIDR" == "$SELECTED_IP" ]] && CT_CIDR=24
                log "Mevcut IP: ${SELECTED_IP}/${CT_CIDR}"
            else
                log "Mevcut CT DHCP kullaniyor, IP bilinmiyor"
                log "Credential/backend guncellemesi yapilmayacak"
                SKIP_CREDENTIALS=true
            fi
            ;;
        2)
            AVAILABLE_ID=$((CT_ID + 1))
            while echo "$USED_IDS" | grep -q "^${AVAILABLE_ID}$"; do
                AVAILABLE_ID=$((AVAILABLE_ID + 1))
            done
            log "Yeni ID: $AVAILABLE_ID"
            CT_ID=$AVAILABLE_ID
            ;;
        3)
            IS_PROTECTED=$(ssh "${SSH_OPTS[@]}" "root@${PVE_IP}" "pct config $CT_ID 2>/dev/null | grep -c 'protection: 1'" || echo "0")
            if [ "$IS_PROTECTED" -eq 1 ]; then
                die "CT $CT_ID korumali durumda - silinemez!
    Bu CT silinmeye karsi korunmustur. Kaldirmak icin:
      pct set $CT_ID -protection 0"
            fi

            echo ""
            err "DIKKAT: CT $CT_ID silinecek!"
            echo "  Bu islem geri alinamaz:"
            echo "    - CT icindeki TUM veriler yok olacak"
            echo "    - Garage veritabani silinecek"
            echo "    - Credential dosyalari gecersiz olacak"
            echo ""
            read -r -p "  Devam etmek istiyor musun? (hayir/E): " DELETE_CONFIRM
            if [[ ! "$DELETE_CONFIRM" =~ ^[Ee]$ ]]; then
                log "Silme iptal edildi"
                exit 0
            fi

            log "CT $CT_ID siliniyor..."
            ssh "${SSH_OPTS[@]}" "root@${PVE_IP}" "pct stop $CT_ID 2>/dev/null; pct destroy $CT_ID --purge"
            ok "CT $CT_ID silindi"
            ;;
        *)
            die "Gecersiz secim"
            ;;
    esac
else
    log "CT $CT_ID kullanimda degil, olusturulacak"
fi
ok "Container ID: $CT_ID"

# --- 4. IP adresi secimi ---
CIDR=""
if [ "$SKIP_SETUP" = true ]; then
    log "Mevcut CT kullaniliyor, IP secimi atlaniyor"
elif [ -n "$SELECTED_IP" ] && [ -n "$CT_CIDR" ]; then
    log "Mevcut IP kullaniliyor: ${SELECTED_IP}/${CT_CIDR}"
    CIDR="$CT_CIDR"
else
log "4/10: IP adresi belirleniyor..."

# Proxmox'tan network bilgisi al - "eval" YERINE guvenli satir-satir parse
NETWORK_INFO=$(ssh "${SSH_OPTS[@]}" "root@${PVE_IP}" bash << 'REMOTE'
  GATEWAY=$(ip route | awk '/default/{print $3; exit}')
  BRIDGE=$(ip -4 addr show | awk '/master/{gsub(/.*master /,""); gsub(/ .*/,""); print; exit}')
  if [ -z "$BRIDGE" ]; then
    BRIDGE=$(awk '/^iface vmbr/{print $2; exit}' /etc/network/interfaces 2>/dev/null)
  fi
  BRIDGE_INFO=$(ip -4 addr show "$BRIDGE" 2>/dev/null | awk '/inet /{print $2}' | head -1)
  echo "GATEWAY=$GATEWAY"
  echo "BRIDGE=$BRIDGE"
  echo "CIDR=$(echo "$BRIDGE_INFO" | cut -d/ -f2)"
  echo "PREFIX=$(echo "$BRIDGE_INFO" | cut -d/ -f1 | sed 's/\.[0-9]*$//')"
REMOTE
)
GATEWAY=""; BRIDGE=""; CIDR=""; PREFIX=""
while IFS='=' read -r key value; do
  case "$key" in
    GATEWAY) GATEWAY="$value" ;;
    BRIDGE)  BRIDGE="$value" ;;
    CIDR)    CIDR="$value" ;;
    PREFIX)  PREFIX="$value" ;;
  esac
done <<< "$NETWORK_INFO"
[ -n "$PREFIX" ] || die "Ag bilgisi alinamadi (bridge/gateway tespit edilemedi)"

# Proxmox'tan kullanilmis IP'leri al
USED_IPS_RAW=$(ssh "${SSH_OPTS[@]}" "root@${PVE_IP}" bash << 'REMOTE'
  for ctid in $(pct list 2>/dev/null | awk 'NR>1{print $1}'); do
    pct config "$ctid" 2>/dev/null | grep -oP 'ip=\K[0-9.]+'
  done
  for vmid in $(qm list 2>/dev/null | awk 'NR>1{print $1}'); do
    qm config "$vmid" 2>/dev/null | grep -oP 'ipconfig[0-9]+: ip=\K[0-9.]+'
  done
  ip -4 addr show vmbr0 2>/dev/null | awk '/inet /{print $2}' | cut -d/ -f1
  ip route | awk '/default/{print $3; exit}'
REMOTE
)

USED_IPS=()
while IFS= read -r ip; do
  [ -n "$ip" ] && USED_IPS+=("$ip")
done <<< "$USED_IPS_RAW"
if [ "${#USED_IPS[@]}" -gt 0 ]; then
  mapfile -t USED_IPS < <(printf '%s\n' "${USED_IPS[@]}" | sort -u)
fi

AVAILABLE_IPS=()
for i in $(seq 100 150); do
  candidate="${PREFIX}.${i}"
  found=0
  for used in "${USED_IPS[@]}"; do
    [ "$candidate" = "$used" ] && { found=1; break; }
  done
  [ "$found" -eq 0 ] && AVAILABLE_IPS+=("$candidate")
done

SELECTED_IP=""
select_garage_ip() {
  local count=${#AVAILABLE_IPS[@]}
  echo ""
  echo "==========================================="
  echo "  IP Adresi Secimi"
  echo "==========================================="
  echo ""
  echo "Ag Bilgisi:"
  echo "  Gateway:     $GATEWAY"
  echo "  Subnet:      $PREFIX.0/$CIDR"
  echo "  Bridge:      $BRIDGE"
  echo ""

  if [ "${#USED_IPS[@]}" -gt 0 ]; then
    echo "Kullanilmis IP'ler (${#USED_IPS[@]} adet):"
    for ip in "${USED_IPS[@]}"; do echo "  $ip"; done
    echo ""
  fi

  if [ "$count" -eq 0 ]; then
    echo "HATA: $PREFIX.100-$PREFIX.150 araliginda musait IP bulunamadi."
    read -r -p "Manuel IP girin (ornek: $PREFIX.100): " manual_ip
    SELECTED_IP="${manual_ip%%/*}"
    return
  fi

  local show=$(( count > 30 ? 30 : count ))
  echo "Musait IP'ler (ilk $show tanesi, $count adet mevcut):"
  echo ""
  local cols=3
  for i in $(seq 0 $((show - 1))); do
    printf "  [%2d] %-15s" "$((i+1))" "${AVAILABLE_IPS[$i]}"
    [ $(( (i+1) % cols )) -eq 0 ] && echo ""
  done
  [ $(( show % cols )) -ne 0 ] && echo ""
  [ "$show" -lt "$count" ] && echo "  ... ve $((count - show)) tane daha"
  echo ""
  echo "Musait IP araligi: $PREFIX.100 - $PREFIX.150"
  read -r -p "Son octeti girin (100-150, Enter=ilk bos IP): " ip_last
  echo ""

  if [ -z "$ip_last" ]; then
    SELECTED_IP="${AVAILABLE_IPS[0]}"
  elif [[ "$ip_last" =~ ^[0-9]+$ ]] && [ "$ip_last" -ge 100 ] && [ "$ip_last" -le 150 ]; then
    candidate="${PREFIX}.${ip_last}"
    found=0
    for avail in "${AVAILABLE_IPS[@]}"; do [ "$avail" = "$candidate" ] && { found=1; break; }; done
    if [ "$found" -eq 1 ]; then
      SELECTED_IP="$candidate"
    else
      USE_EXISTING=0
      for used in "${USED_IPS[@]}"; do [ "$used" = "$candidate" ] && { USE_EXISTING=1; break; }; done
      if [ "$USE_EXISTING" -eq 1 ]; then
        err "Bu IP (${PREFIX}.${ip_last}) kullanimda!"
        SELECTED_IP=""
      else
        SELECTED_IP="$candidate"
      fi
    fi
  else
    echo "Gecersiz aralik: 100-150 arasi sayi girin veya Enter ile bos birakin."
    select_garage_ip
    return
  fi
}

select_garage_ip
ok "IP secildi: ${SELECTED_IP}/${CIDR}"
fi

# --- 5-7. Kurulum (sadece yeni CT icin) ---
if [ "$SKIP_SETUP" != true ]; then
    log "5/10: Setup scripti kopyalaniyor..."
    scp "${SSH_OPTS[@]}" "$SCRIPT_DIR/setup-garage-lxc.sh" "root@${PVE_IP}:/root/setup-garage-lxc.sh"
    ssh "${SSH_OPTS[@]}" "root@${PVE_IP}" "chmod +x /root/setup-garage-lxc.sh"
    ok "Script kopyalandi"

    log "6/10: Garage kuruluyor (biraz zaman alabilir)..."
    ssh "${SSH_OPTS[@]}" "root@${PVE_IP}" "TOFU_BACKEND=${TOFU_BACKEND} GARAGE_CT_CORES=${CT_CORES} GARAGE_CT_RAM=${CT_MEMORY} GARAGE_CT_DISK=${CT_DISK} /root/setup-garage-lxc.sh $CT_ID $CT_STORAGE ${SELECTED_IP}/${CIDR} \"$TEMPLATE\""
    ok "Kurulum tamamlandi"

    log "7/10: Garage durumu dogrulaniyor..."
    sleep 3
    STATUS=$(ssh "${SSH_OPTS[@]}" "root@${PVE_IP}" "pct exec $CT_ID -- rc-service garage status 2>/dev/null" || echo "failed")
    if echo "$STATUS" | grep -q "started"; then
        ok "Garage calisiyor"
    else
        die "Garage baslatilamadi. Durum: $STATUS
    Manuel kontrol:
      ssh root@$PVE_IP
      pct exec $CT_ID -- garage status"
    fi

    # --- 7b. tofu-backend=false → bu Garage tofu state backend'i DEGILDIR ---
    # Fiziksel karsiligi: setup'in olusturdugu opentofu-state placeholder kovasi
    # ve opentofu-key artik yaratilmiyor (root cook sonucu role gore). Canlilik
    # icin node_exporter kurulur.
    if [ "$TOFU_BACKEND" = false ]; then
        log "7b/10: tofu-backend=false — state bootstrap'i atlandi (kova/key uretilmeyecek)"
        ok "State bootstrap'i atlandi (TOFU_BACKEND=false)"

        log "7b/10: node_exporter kuruluyor (canlilik scrape)..."
        # Alpine paket adi "node_exporter" DEGIL "prometheus-node-exporter"dir
        # (apk add node_exporter -> "no such package"). Servis adi kurulumdan
        # sonra /etc/init.d altindan tespit edilir (tahmin yok).
        NODE_EXPORTER_CMD="pct exec $CT_ID -- ash -c 'apk add prometheus-node-exporter && SVC=\$(ls /etc/init.d/ | grep -i exporter | head -1) && rc-update add \"\$SVC\" default && (rc-service \"\$SVC\" restart || rc-service \"\$SVC\" start)'"
        NODE_EXP_OK=false
        NODE_EXP_LOG="/tmp/garage-setup-node-exp-${CT_ID}.log"
        for _try in 1 2; do
            if ssh "${SSH_OPTS[@]}" "root@${PVE_IP}" "$NODE_EXPORTER_CMD" >"$NODE_EXP_LOG" 2>&1; then
                NODE_EXP_OK=true
                break
            fi
            [ "$_try" -eq 1 ] && log "Retrying node_exporter installation (2/2)..."
        done
        if [ "$NODE_EXP_OK" = true ]; then
            rm -f "$NODE_EXP_LOG"
            ok "node_exporter kuruldu ve baslatildi"
        else
            echo ""
            warn "node_exporter installation failed twice. Remote output:"
            sed 's/^/    /' "$NODE_EXP_LOG" 2>/dev/null || true
            rm -f "$NODE_EXP_LOG"
            echo ""
            echo "  Without node_exporter this host has no liveness scrape:"
            echo "  Prometheus cannot see it and host-level alerts stay blind."
            echo ""
            read -r -p "  Continue without node_exporter? [y/N]: " NODE_EXP_CHOICE
            NODE_EXP_CHOICE=${NODE_EXP_CHOICE:-N}
            if [[ "$NODE_EXP_CHOICE" =~ ^[Yy]$ ]]; then
                warn "Continuing WITHOUT node_exporter — install manually later:"
                warn "  ssh root@${PVE_IP} 'pct exec $CT_ID -- apk add prometheus-node-exporter && rc-update add node_exporter default && rc-service node_exporter start'"
            else
                die "Aborted by user choice. Fix the apk error above, then rerun chef.sh (completed steps are idempotent)."
            fi
        fi

        # --- python3 (ansible ZORUNLULUGU — maintenance rolu ping dahil tum
        # modulleri hedefte python ile kosturur). node_exporter'dan farkli
        # olarak opsiyonel DEGILDIR: kurulamazsa kurulum durur.
        log "7b/10: python3 kuruluyor (ansible zorunlulugu)..."
        PY3_OK=false
        PY3_LOG="/tmp/garage-setup-py3-${CT_ID}.log"
        for _try in 1 2; do
            if ssh "${SSH_OPTS[@]}" "root@${PVE_IP}" "pct exec $CT_ID -- apk add python3" >"$PY3_LOG" 2>&1; then
                PY3_OK=true
                break
            fi
            [ "$_try" -eq 1 ] && log "Retrying python3 installation (2/2)..."
        done
        if [ "$PY3_OK" = true ]; then
            rm -f "$PY3_LOG"
            ok "python3 kuruldu"
        else
            echo ""
            warn "python3 installation failed twice (ansible cannot run without it). Remote output:"
            sed 's/^/    /' "$PY3_LOG" 2>/dev/null || true
            rm -f "$PY3_LOG"
            die "python3 sart — apk hatasini duzeltip chef.sh'i yeniden kostur (tamamlanan adimlar idempotent)."
        fi
    fi
fi

# Mevcut CT yeniden kullanildiginda da tofu-backend=false anlami gecerli olmali:
if [ "$TOFU_BACKEND" = false ] && [ "$SKIP_SETUP" = true ]; then
    warn "Mevcut CT kullaniliyor — eski opentofu-state kovasi varsa bir kere elle sil:"
    warn "  ssh root@${PVE_IP} 'pct exec $CT_ID -- garage bucket delete opentofu-state --yes; garage key delete opentofu-key --yes'"
fi

# --- 7c. Garage2 SSH (maintenance/ansible erisimi — GARAGE_ENABLE_SSH) ---
# Yeni ve mevcut CT'de ayni adim calisir (idempotent; ilk state'li kurulumun
# uzerine de eklenebilir). Anahtar maintenance.ini garage2 satiriyla aynidir:
#   GARAGE_SSH_PUB_KEY veya ~/.ssh/id_ed25519.pub
if [ "$GARAGE_ENABLE_SSH" = true ]; then
    log "7c/10: Garage2 icine SSH kuruluyor (openssh + public key)..."
    SSH_PUB_FILE="${GARAGE_SSH_PUB_KEY:-$HOME/.ssh/id_ed25519.pub}"
    if [ ! -f "$SSH_PUB_FILE" ]; then
        die "Public key bulunamadi: $SSH_PUB_FILE
    GARAGE_SSH_PUB_KEY ile ver veya anahtar olustur:
      ssh-keygen -t ed25519 -f ~/.ssh/id_ed25519"
    fi
    SSH_PUB_KEY="$(cat "$SSH_PUB_FILE")"
    ssh "${SSH_OPTS[@]}" "root@${PVE_IP}" "pct exec $CT_ID -- ash -c \"
        apk add openssh >/dev/null 2>&1 || true
        rc-update add sshd default >/dev/null 2>&1 || true
        rc-service sshd start >/dev/null 2>&1 || rc-service sshd restart >/dev/null 2>&1 || true
        mkdir -p /root/.ssh && chmod 700 /root/.ssh
        touch /root/.ssh/authorized_keys && chmod 600 /root/.ssh/authorized_keys
        grep -qxF '$SSH_PUB_KEY' /root/.ssh/authorized_keys 2>/dev/null || echo '$SSH_PUB_KEY' >> /root/.ssh/authorized_keys
    \""
    ok "SSH kuruldu (sshd + key eklendi)"
    if [ -n "$SELECTED_IP" ]; then
        # Stale-key tespiti baglanti CIKTISINA gore yapilir — on kontrol yok.
        # İmza ayrimi: degismis-key "REMOTE HOST IDENTIFICATION HAS CHANGED" /
        # "Offending ... key" basar; BILINMEYEN host (sifir CT) yalniz
        # "Host key verification failed" verir. Bu yuzden desende jenerik
        # "Host key verification failed" YOK — olsaydi sifir CT'de bile
        # yanlis soru sorulurdu. accept-new degismis anahtari reddettigi icin
        # once imza yakalanip sorulur, sonra temizlenir. Dead host farkli
        # hata verir ve soruyu tetiklemez.
        # Fresh CT'de sshd henuz aciliyor olabilir: "connection refused" race,
        # changed-key imzasini gizlemesin diye probe tekrarlanir.
        SSH_PROBE=""
        for _try in 1 2 3 4 5 6; do
            SSH_PROBE="$(ssh -o BatchMode=yes -o StrictHostKeyChecking=yes -o ConnectTimeout=5 "root@${SELECTED_IP}" true 2>&1 || true)"
            # Stale key imzasi: hemen sor.
            echo "$SSH_PROBE" | grep -qiE "REMOTE HOST IDENTIFICATION HAS CHANGED|Offending .* key" && break
            # sshd aciliyor: bekle, tekrar dene. Baska hata/basarida dur.
            echo "$SSH_PROBE" | grep -qiE "Connection refused" || break
            sleep 5
        done
        if echo "$SSH_PROBE" | grep -qiE "REMOTE HOST IDENTIFICATION HAS CHANGED|Offending .* key"; then
            echo ""
            warn "Stale SSH host key detected for ${SELECTED_IP}."
            echo "  This container was likely rebuilt and its host key changed."
            echo "  The old key must be removed (ssh-keygen -R) before connecting."
            echo ""
            read -r -p "  Remove the old host key for ${SELECTED_IP} and accept the new one? [Y/n]: " KEYGEN_CHOICE
            KEYGEN_CHOICE=${KEYGEN_CHOICE:-Y}
            if [[ "$KEYGEN_CHOICE" =~ ^[Yy]$ ]]; then
                ssh-keygen -R "$SELECTED_IP" >/dev/null 2>&1 || true
                ok "Old host key removed for ${SELECTED_IP}"
            else
                warn "Old host key kept — SSH verification skipped (pre/maintenance-env-check retries later)"
            fi
        fi
        if ssh -o BatchMode=yes -o StrictHostKeyChecking=accept-new -o ConnectTimeout=5 "root@${SELECTED_IP}" true 2>/dev/null; then
            ok "Garage2 ssh dogrulandi: root@${SELECTED_IP}"
        else
            warn "Garage2 ssh henuz dogrulanamadi (root@${SELECTED_IP}) — pre/maintenance-env-check yeniden dener"
        fi
    fi
fi

# --- 8. Credential kopyala ---
if [ "$SKIP_CREDENTIALS" != true ]; then
    log "8/10: Credential dosyasi kopyalaniyor..."
    "$SCRIPT_DIR/get-credentials.sh" --host "$PVE_IP" --ctid "$CT_ID"
    ok "Credential kopyalandi ve korundu (chmod 600)"

    if [ "$TOFU_BACKEND" = true ]; then
        log "9/10: Backend dosyalari olusturuluyor..."
        ENCRYPT_FLAG=(); [ "$ENCRYPT" = true ] && ENCRYPT_FLAG=(--encrypt)
        "$SCRIPT_DIR/generate-garage-backend.sh" "$SCRIPT_DIR/garage-${CT_ID}-credentials.txt" "${ENCRYPT_FLAG[@]}" --env "$ENV_NAME"
        ok "Backend dosyalari olusturuldu"
    else
        log "9/10: Tofu backend dosyalari ATLANDI (--tofu-backend=false)"
        ok "Bu Garage tofu state backend'i DEGILDIR — tofu/backends/ dokunulmadi"
        [ "$ENCRYPT" = true ] && warn "--encrypt yalniz tofu backend uretimini etkiler; yok sayildi"
        [ "$ENV_NAME" != "dev" ] && warn "--env yalniz tofu backend uretimini etkiler; yok sayildi"
    fi
fi

# --- 10. CT koruma ---
log "10/10: CT silinmeye karsi korunuyor..."
echo ""
read -r -p "  CT $CT_ID silinmeye karsi korunsun mu? (E/h): " PROTECT_CHOICE
PROTECT_CHOICE=${PROTECT_CHOICE:-E}
if [[ "$PROTECT_CHOICE" =~ ^[Ee]$ ]]; then
    ssh "${SSH_OPTS[@]}" "root@${PVE_IP}" "pct set $CT_ID -protection 1"
    ok "CT $CT_ID korumaya alindi"
else
    log "CT korumasi etkinlestirilmedi"
fi

# --- Sonuc ---
echo ""
echo -e "${C_GREEN}========================================${C_RESET}"
echo -e "${C_GREEN}   Kurulum Tamamlandi!${C_RESET}"
echo -e "${C_GREEN}========================================${C_RESET}"
echo ""
echo "Container ID: $CT_ID"
[ -n "$SELECTED_IP" ] && echo "Garage IP:    ${SELECTED_IP}/${CT_CIDR:-${CIDR:-24}}"
echo ""
if [ "$TOFU_BACKEND" = true ]; then
    echo "Sonraki adim:"
    echo "  cd tofu/stacks/k8s-cluster"
    echo "  tofu init -backend-config=../../backends/k8s-cluster.backend.tfbackend"
    echo "  tofu validate"
    echo "  tofu plan"
    echo "  tofu apply"
else
    echo "Bu Garage tofu state backend'i DEGILDIR — tofu kurulum adimi YOK."
    echo "Backup garagelari maintenance envanterine girer; envanter simdi uretiliyor."
    echo ""
    if [ "$GARAGE_ENABLE_SSH" = true ]; then
        # Backup sartlari burada saglanmis durumda (TOFU_BACKEND=false +
        # ENABLE_SSH=true): sifreler ct-<ID> altina uretilir (best-effort,
        # mevcut sifrenin uzerine yazmaz).
        GEN_PASSWORDS="$SCRIPT_DIR/gen-restic-passwords.sh"
        if [ -x "$GEN_PASSWORDS" ]; then
            log "Restic repo sifreleri uretiliyor (best-effort, uzerine yazmaz)..."
            if "$GEN_PASSWORDS" --ct-id "$CT_ID"; then
                ok "restic sifreleri hazir (outputs/garage-backups/ct-${CT_ID}/)"
            else
                warn "Sifre uretimi basarisiz (python3/pyyaml eksik olabilir) — chef'i tekrar kostur"
            fi
        else
            warn "Sifre uretici bulunamadi: $GEN_PASSWORDS — chef'i tekrar kostur"
        fi
        echo ""
        GEN_INVENTORY="$SCRIPT_DIR/gen-maintenance-inventory.sh"
        if [ -z "${SELECTED_IP:-}" ]; then
            warn "Garage IP bilinmiyor (DHCP?) — maintenance envanteri uretilemedi, statik IP ile tekrar kostur"
        elif [ -x "$GEN_INVENTORY" ]; then
            log "Maintenance envanteri uretiliyor (best-effort)..."
            if "$GEN_INVENTORY" --garage-ip "$SELECTED_IP" --ct-id "$CT_ID"; then
                ok "maintenance-${CT_ID}.ini.generated guncellendi ([garage-backup] dahil)"
            else
                warn "Envanter uretilemedi (tofu apply cikti(d)lari eksik olabilir) — chef'i tekrar kostur"
            fi
        else
            warn "Generator bulunamadi: $GEN_INVENTORY — chef'i tekrar kostur"
        fi
    else
        log "GARAGE_ENABLE_SSH=false — maintenance envanteri uretilmedi (ssh'siz CT)."
    fi
    echo ""
    echo "Sonraki adimlar (backup garagelari):"
    echo "  ./scripts/garage-setup/chef.sh  # sifre/envanter atlandiysa (mevcut CT kullanilir)"
    echo "  ansible-playbook -i ansible/inventory/maintenance-${CT_ID}.ini.generated ansible/playbooks/maintenance.yml"
fi
