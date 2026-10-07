#!/usr/bin/env bash
# deploy-maintenance.sh — Yedekleme kontrol menusu (remote controller)
#
# =============================================================================
# HERHANGI BIR YERDEN CALISIR (local workstation veya PVE)
# ===========================================================================
#
# Ilke: is, kaynagin/verinin oldugu hedefte calisir; bu script sadece dispatch eder.
#   1 disk    → PVE (vzdump)           — yerel vzdump yoksa SSH
#   2 etcd    → K8s Master             — SSH
#   3 openbao → OpenBao dugumu         — once SSH; yoksa PVE pct fallback
#   5 durum   → her hedefte .state     — remote healthcheck (--only), birlesik exit
#
# Hedefe maintenance/ gonderilir; garage credential yalnizca --creds <dosya>
# ile gonderilir (verilmezse uyarilir). Hedef .state'e DOKUNULMAZ
# (exclude .state). Hedefte rsync yoksa tar-over-ssh fallback kullanilir.
#
# Menü:
#   1) PVE disk     — backup-full.sh
#   2) Master etcd  — backup-etcd.sh
#   3) openbao S3   — backup-openbao.sh
#   4) Tumu         — 1→2→3
#   5) Durum        — remote healthcheck (Master + PVE + OpenBao)
#   0) Cikis
#
# Ortamlar (env ile ezilebilir) — inventory/pve-discovered ile hizali:
#   MAINT_MASTER_SSH   varsayilan: ubuntu@164.102.98.174
#   MAINT_MASTER_PATH  varsayilan: /home/ubuntu/tofu-lar
#   MAINT_OPENBAO_SSH  varsayilan: root@164.102.98.186
#   MAINT_OPENBAO_PATH varsayilan: /root/tofu-lar
#   MAINT_PVE_SSH      varsayilan: root@164.102.98.16
#   MAINT_PVE_PATH     varsayilan: /root/tofu-lar
#   MAINT_CT_OPENBAO   varsayilan: 301   (pct fallback)
#   MAINT_VM_DISK      varsayilan: 300
#   MAINT_NO_SYNC=1    sync atla (hedefte klon zaten guncelse)
#
# Kullanim:
#   ./deploy/deploy-maintenance.sh            # interaktif menu
#   ./deploy/deploy-maintenance.sh --once 5   # tek islem (CI/cron)
#   ./deploy/deploy-maintenance.sh --help

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MAINT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
PROJECT_DIR="$(cd "${MAINT_DIR}/.." && pwd)"
# shellcheck source=/dev/null
source "${MAINT_DIR}/_common.sh"

MASTER_SSH="${MAINT_MASTER_SSH:-ubuntu@164.102.98.174}"
MASTER_PATH="${MAINT_MASTER_PATH:-/home/ubuntu/tofu-lar}"
OPENBAO_SSH="${MAINT_OPENBAO_SSH:-root@164.102.98.186}"
OPENBAO_PATH="${MAINT_OPENBAO_PATH:-/root/tofu-lar}"
PVE_SSH="${MAINT_PVE_SSH:-root@164.102.98.16}"
PVE_PATH="${MAINT_PVE_PATH:-/root/tofu-lar}"
CT_OPENBAO="${MAINT_CT_OPENBAO:-301}"
VM_DISK="${MAINT_VM_DISK:-300}"
NO_SYNC="${MAINT_NO_SYNC:-0}"

# rsync/tar veri yolu icin -n YOK; plain komutlar _ssh ile stdin kapatir
# ControlMaster: ayni hedefe arka arkaya cok ssh — baglantiyi yeniden kullan (banner timeout onler)
_SSH_CTL_DIR="${XDG_RUNTIME_DIR:-${TMPDIR:-/tmp}}/tofu-lar-ssh"
mkdir -p "$_SSH_CTL_DIR" 2>/dev/null || true
SSH_OPTS=(
    -o BatchMode=yes
    -o ConnectTimeout=15
    -o StrictHostKeyChecking=accept-new
    -o ControlMaster=auto
    -o ControlPersist=90
    -o ControlPath="${_SSH_CTL_DIR}/%r@%h:%p"
)

# Plain remote komut: local stdin (menü pipe/cron) yutulmasin
_ssh() {
    ssh "${SSH_OPTS[@]}" "$@" </dev/null
}

ONCE=""
CREDS_SRC=""

usage() {
    cat << EOF
Kullanim: $0 [--once <1|2|3|4|5>] [--creds <garage-credentials.txt>]

  --once <n>   Menuyu atla, tek islem calistir ve cik (1=disk 2=etcd 3=openbao 4=tumu 5=durum)
  --creds <f>  Legacy restore fallback icin garage credential dosyasini hedefe kopyalar
               (verilmezse kopyalanmaz ve uyarilir; production'da storage: restic)
  -h, --help   Bu yardimi goster

Hedefler (env):
  MAINT_MASTER_SSH=$MASTER_SSH
  MAINT_MASTER_PATH=$MASTER_PATH
  MAINT_OPENBAO_SSH=$OPENBAO_SSH
  MAINT_OPENBAO_PATH=$OPENBAO_PATH
  MAINT_PVE_SSH=$PVE_SSH
  MAINT_PVE_PATH=$PVE_PATH
  MAINT_CT_OPENBAO=$CT_OPENBAO
  MAINT_VM_DISK=$VM_DISK
  MAINT_NO_SYNC=$NO_SYNC
EOF
    exit 1
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --once) ONCE="${2:-}"; shift 2 ;;
        --creds) CREDS_SRC="$2"; shift 2 ;;
        -h|--help) usage ;;
        *) usage ;;
    esac
done

# ---------------------------------------------------------------------------
# Hedefe maintenance + credential gonder (.state hariç — remote state korunur)
# ---------------------------------------------------------------------------
_sync_tree() {
    local host="$1" root="$2"
    if _ssh "$host" "command -v rsync" &>/dev/null; then
        if rsync -a --exclude='.state/' -e "ssh ${SSH_OPTS[*]}" \
            "${MAINT_DIR}/" "${host}:${root}/maintenance/"; then
            return 0
        fi
        log_warn "rsync basarisiz — tar fallback deneniyor"
    fi
    if tar -C "$MAINT_DIR" -cf - --exclude='.state' . \
        | ssh "${SSH_OPTS[@]}" "$host" "tar -C '${root}/maintenance' -xf -"; then
        return 0
    fi
    log_error "sync basarisiz: $host"
    return 1
}

sync_to_target() {
    local host="$1" root="$2"
    if [ "$NO_SYNC" = "1" ]; then
        return 0
    fi
    if ! _ssh "$host" "mkdir -p '${root}/maintenance'"; then
        log_error "remote mkdir basarisiz: ${host}:${root}"
        return 1
    fi
    log_info "Sync: maintenance/ -> ${host}:${root}/maintenance/ (.state hariç)"
    if ! _sync_tree "$host" "$root"; then
        return 1
    fi
    # Garage credential: yalnizca --creds <dosya> ile (sabit yol/kod yok).
    # Verilmezse legacy restore fallback creds'siz kalir — uyarilir.
    if [ -n "$CREDS_SRC" ]; then
        if [ ! -f "$CREDS_SRC" ]; then
            log_error "credential dosyasi bulunamadi: $CREDS_SRC"
        elif _ssh "$host" "mkdir -p '${root}/scripts/garage-setup'" 2>/dev/null; then
            if ! scp -q "${SSH_OPTS[@]}" "$CREDS_SRC" "${host}:${root}/scripts/garage-setup/" 2>/dev/null; then
                log_warn "credential scp basarisiz: $host"
            fi
        fi
    else
        log_warn "garage credential tasinmadi — legacy restore fallback gerekecekse: $0 --creds <garage-credentials.txt>"
    fi
    # OpenBao root token credentials (raft snapshot yetkisi) — 0600, loglanmaz
    local bao_creds="${PROJECT_DIR}/ansible/outputs/openbao/openbao-credentials.yml"
    if [ -f "$bao_creds" ]; then
        if _ssh "$host" "mkdir -p '${root}/ansible/outputs/openbao'" 2>/dev/null; then
            scp -q "${SSH_OPTS[@]}" "$bao_creds" "${host}:${root}/ansible/outputs/openbao/" 2>/dev/null \
                || log_warn "openbao credentials scp basarisiz: $host"
            _ssh "$host" "chmod 600 '${root}/ansible/outputs/openbao/openbao-credentials.yml'" 2>/dev/null || true
        fi
    fi
    _ssh "$host" "find '${root}/maintenance' -name '*.sh' -exec chmod +x {} +" 2>/dev/null || true
    return 0
}

remote_has_script() {
    local host="$1" abs="$2" i
    # SSH banner timeout gecici olabilir — kisa retry
    for i in 1 2 3; do
        if _ssh "$host" "test -x '$abs'" 2>/dev/null; then
            return 0
        fi
        sleep 1
    done
    return 1
}

# Master: etcdctl yok — containerd snapshot'indan $HOME/bin'e kopyala (sudo -n)
# heredoc icin stdin gerekir — _ssh kullanilmasin (</dev/null heredoc'u keser)
ensure_master_etcdctl() {
    ssh "${SSH_OPTS[@]}" "$MASTER_SSH" 'bash -s' <<'EOS' || return 1
set -e
mkdir -p "$HOME/bin"
if command -v etcdctl >/dev/null 2>&1 || [ -x "$HOME/bin/etcdctl" ]; then
    exit 0
fi
# containerd dizini ubuntu'dan glob/ls edilemez — sudo find ile bul
src="$(sudo -n find /var/lib/containerd -path '*/fs/usr/local/bin/etcdctl' -type f 2>/dev/null | head -1 || true)"
if [ -z "$src" ] || ! sudo -n test -x "$src"; then
    echo "etcdctl bulunamadi (container snapshot yok veya sudo -n yok)" >&2
    exit 1
fi
sudo -n cp "$src" /tmp/etcdctl.bin
sudo -n chown "$(id -u):$(id -g)" /tmp/etcdctl.bin
sudo -n chmod 755 /tmp/etcdctl.bin
mv /tmp/etcdctl.bin "$HOME/bin/etcdctl"
"$HOME/bin/etcdctl" version | head -1
EOS
}

# Hedefte s3cmd yoksa kur (Garage ile aws CLI imza uyumsuz — s3cmd tercih)
ensure_s3_client() {
    local host="$1" root="$2" mode="$3" # mode: user|root
    if _ssh "$host" "command -v s3cmd" &>/dev/null; then
        return 0
    fi
    log_info "s3cmd yok ($host) — kurulum deneniyor ($mode)"
    local setup
    if [ "$mode" = "user" ]; then
        setup='set -e
command -v s3cmd && exit 0
sudo -n apt-get update -qq
sudo -n DEBIAN_FRONTEND=noninteractive apt-get install -y -qq s3cmd
command -v s3cmd
s3cmd --version | head -1'
    else
        setup='set -e
command -v s3cmd && exit 0
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y -qq s3cmd
command -v s3cmd
s3cmd --version | head -1'
    fi
    if _ssh "$host" "bash -lc $(printf '%q' "$setup")"; then
        return 0
    fi
    log_warn "s3cmd kurulumu basarisiz: $host — hedefe elle s3cmd kurulmali"
    return 1
}

run_remote() {
    local host="$1" root="$2" rel="$3"
    shift 3
    if ! sync_to_target "$host" "$root"; then
        return 1
    fi
    local abs="${root}/maintenance/${rel}"
    if ! remote_has_script "$host" "$abs"; then
        log_error "Hedefte script yok veya executable degil: ${host}:${abs}"
        log_info "Kontrol: ssh ${host} 'ls -la ${root}/maintenance/'"
        return 1
    fi
    _ssh "$host" "export PATH=\"\$HOME/bin:\$PATH\"; cd '${root}/maintenance' && ./${rel}" "$@"
}

# ---------------------------------------------------------------------------
# Islemler
# ---------------------------------------------------------------------------

run_pve_disk() {
    log_sep
    log_info "1) PVE disk backup (CT $VM_DISK) — hedef: $PVE_SSH ($PVE_PATH)"
    local rel="backup/vm-disk/backup-full.sh"
    # Yerel PVE'de oturuyorsak (vzdump var) yerel calistir
    if command -v vzdump &>/dev/null; then
        if [ ! -x "${MAINT_DIR}/backup/vm-disk/backup-full.sh" ]; then
            chmod +x "${MAINT_DIR}/backup/vm-disk/backup-full.sh" 2>/dev/null || true
        fi
        "${MAINT_DIR}/backup/vm-disk/backup-full.sh" --vmid "$VM_DISK"
        return $?
    fi
    if ! run_remote "$PVE_SSH" "$PVE_PATH" "$rel" --vmid "$VM_DISK"; then
        log_error "disk backup basarisiz (SSH: $PVE_SSH)"
        log_info "Kontrol: ssh $PVE_SSH 'command -v vzdump; ls ${PVE_PATH}/maintenance/backup/vm-disk/'"
        return 1
    fi
    log_ok "disk backup tamamlandi (uzak PVE)"
}

run_master_etcd() {
    log_sep
    log_info "2) Master etcd snapshot -> S3 tier (SSH: $MASTER_SSH, path: $MASTER_PATH)"
    if ! ensure_master_etcdctl; then
        log_error "etcdctl hazirlanamadi (Master)"
        return 1
    fi
    ensure_s3_client "$MASTER_SSH" "$MASTER_PATH" "user" || true
    if ! run_remote "$MASTER_SSH" "$MASTER_PATH" "backup/app-data/backup-etcd.sh"; then
        log_error "etcd backup basarisiz (SSH: $MASTER_SSH)"
        log_info "Kontrol: ssh $MASTER_SSH 'ls ${MASTER_PATH}/maintenance/backup/app-data/'"
        return 1
    fi
    log_ok "etcd backup tamamlandi (uzak Master)"
}

run_openbao_s3() {
    log_sep
    log_info "3) OpenBao raft -> S3 tier (SSH: $OPENBAO_SSH; fallback: pct $CT_OPENBAO)"
    ensure_s3_client "$OPENBAO_SSH" "$OPENBAO_PATH" "root" || true
    # Birincil: raft'in oldugu dugum (CT301 = OPENBAO_SSH)
    if run_remote "$OPENBAO_SSH" "$OPENBAO_PATH" "backup/app-data/backup-openbao.sh"; then
        log_ok "openbao backup tamamlandi (SSH $OPENBAO_SSH)"
        return 0
    fi
    log_warn "OpenBao SSH yolu basarisiz — PVE pct fallback deneniyor..."
    if ! sync_to_target "$PVE_SSH" "$PVE_PATH"; then
        return 1
    fi
    local abs="${PVE_PATH}/maintenance/backup/app-data/backup-openbao.sh"
    if ! _ssh "$PVE_SSH" "pct exec $CT_OPENBAO -- test -x '$abs'"; then
        log_error "openbao script CT icinde yok: $abs"
        log_info "Not: CT icine maintenance deploy ayri adimdir; ya da:"
        log_info "  ssh $OPENBAO_SSH 'ls ${OPENBAO_PATH}/maintenance/backup/app-data/'"
        return 1
    fi
    if ! _ssh "$PVE_SSH" "pct exec $CT_OPENBAO -- bash -lc '$abs'"; then
        log_error "openbao backup basarisiz (pct $CT_OPENBAO)"
        return 1
    fi
    log_ok "openbao backup tamamlandi (pct $CT_OPENBAO)"
}

run_all() {
    local rc=0
    run_pve_disk    || rc=1
    run_master_etcd || rc=1
    run_openbao_s3  || rc=1
    if [ "$rc" -eq 0 ]; then
        log_ok "Tum yedekler tamamlandi"
    else
        log_error "Bazilari basarisiz — loglari yukarida inceleyin"
    fi
    return "$rc"
}

# Her hedefte ilgili isim icin remote health; birlesik exit
run_status() {
    log_sep
    log_info "5) Durum — remote healthcheck (Master etcd / PVE vm-disk / OpenBao openbao)"
    local rc=0

    # (host, path, --only, etiket)
    local -a checks=(
        "${MASTER_SSH}|${MASTER_PATH}|etcd|Master"
        "${PVE_SSH}|${PVE_PATH}|vm-disk|PVE"
        "${OPENBAO_SSH}|${OPENBAO_PATH}|openbao|OpenBao"
    )
    local entry h p o lbl
    for entry in "${checks[@]}"; do
        IFS='|' read -r h p o lbl <<< "$entry"
        log_info "--- $lbl ($h) ---"
        if ! sync_to_target "$h" "$p"; then
            echo "[SORUN] $lbl — sync basarisiz"
            rc=1
            continue
        fi
        if ! _ssh "$h" "cd '$p/maintenance/backup' && ./healthcheck.sh --only '$o'"; then
            echo "[SORUN] $lbl — healthcheck exit != 0"
            rc=1
        fi
    done

    if [ "$rc" -eq 0 ]; then
        log_ok "Durum: tum hedefler guncel (exit 0)"
    else
        log_error "Durum: en az bir hedefte sorun (exit $rc)"
    fi
    return "$rc"
}

dispatch() {
    local n="$1"
    case "$n" in
        1) run_pve_disk ;;
        2) run_master_etcd ;;
        3) run_openbao_s3 ;;
        4) run_all ;;
        5) run_status ;;
        0) return 0 ;;
        *) log_warn "Gecersiz secim: $n"; return 1 ;;
    esac
}

if [ -n "$ONCE" ]; then
    dispatch "$ONCE"
    exit $?
fi

# Menu loop — 0/q/exit'e kadar
if [ -t 1 ] && [ "$(tput colors 2>/dev/null || echo 0)" -ge 8 ]; then
    BOLD="$(tput bold)"; GREEN="$(tput setaf 2)"; CYAN="$(tput setaf 6)"; RESET="$(tput sgr0)"
else
    BOLD=""; GREEN=""; CYAN=""; RESET=""
fi

show_menu() {
    log_sep
    echo "  ${BOLD}${GREEN}tofu-lar Maintenance Deploy${RESET}  (remote controller)"
    log_sep
    echo ""
    echo "  ${CYAN}1)${RESET} PVE disk      — backup-full.sh -> $PVE_SSH"
    echo "  ${CYAN}2)${RESET} Master etcd   — backup-etcd.sh -> $MASTER_SSH"
    echo "  ${CYAN}3)${RESET} openbao S3    — backup-openbao.sh -> $OPENBAO_SSH"
    echo "  ${CYAN}4)${RESET} Tumu          — 1 -> 2 -> 3"
    echo "  ${CYAN}5)${RESET} Durum         — remote health (3 hedef, birlesik exit)"
    echo "  ${CYAN}0)${RESET} Cikis"
    echo ""
}

# Menü stdin'i FD3'e sabitle — ssh/tar/rsync pipe'i yutmasin
exec 3<&0
while true; do
    show_menu
    read -r -p "  ${BOLD}Secim${RESET} [0-5]: " CHOICE <&3
    echo ""
    case "$CHOICE" in
        0|q|Q) log_info "Cikiliyor"; exit 0 ;;
        1|2|3|4|5)
            dispatch "$CHOICE" || true
            echo ""
            read -r -p "  Devam etmek icin Enter'a basin..." _ <&3
            ;;
        *) log_warn "Gecersiz secim: $CHOICE" ;;
    esac
    echo ""
done
