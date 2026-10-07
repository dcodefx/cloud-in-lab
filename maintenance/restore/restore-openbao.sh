#!/usr/bin/env bash
# restore-openbao.sh — OpenBao raft snapshot'ini geri yukler
#
# =============================================================================
# OPENBAO LXC (CT 301) UZERINDE CALISIR
# =============================================================================
#
# Neden CT301: bu hostta openbao-{daily,weekly,monthly}.env + restic parolasi
# vardir (rol yalnizca job'in sahibi hosta dagitir) ve agent socket burada.
# Disaridan calistirmaya calisirsa: env dosyalari yok -> net hata mesaji.
#
# Ne yapar:
#   1. Pre-flight : OpenBao unsealed mi? (sealed ise API kullanilamaz)
#   2. Onay       : geri alinamaz islem
#   3. ROLLBACK   : mevcut durumun snapshot'ini al (geri donus emnigi)
#   4. Indir      : restic'ten en guncel .snap (veya --snapshot ile verilen)
#   5. Dogrula    : verify_raft_snapshot
#   6. Login      : AppRole bao-raft-restore (policy: read+update+force)
#   7. Yukle      : POST /v1/sys/storage/raft/snapshot
#                   (--force ile /v1/sys/storage/raft/snapshot-force)
#   8. DOGRULA    : 204 = "kabul edildi", "bitti" degil. `bao status`
#                   unsealed olana kadar beklenir (GONDERILDI -> DOGRULANDI
#                   / DOGRULANMADI). DOGRULANMADI ise script exit 1 verir.
#   9. Rapor      : ne yuklendi, rollback dosyasi nerede, sonraki adimlar
#
# KIMLIK: root token KALDIRILDI (backup tarafiyla ayni sebepten, session-080).
# Tek seferlik AppRole login kullanilir; kalici bir token dosyaya yazilmaz.
# Policy/roller: docs/tr/openbao/openbao-rbac.md B11 / P15.
#
# DIKKAT: `snapshot restore` API uzerinden calisir → instance UNSEALED
# olmak ZORUNDA. Sealed instance'i bu yolla kurtaramazsin; once unseal gerekir
# (scripts/openbao-unseal/unseal.sh, 3/5 pay controller'da).
#
# UYARI: Geri yukleme OpenBao'nun TUM verisini snapshot anina dondurur.
#   Snapshot anindan sonra uretilen her sey (yeni KV sirlari, yeni PKI sertifikalari,
#   yeni transit key'ler, degisen policy'ler) KAYBOLUR.
#
# Kullanim:
#   ./restore-openbao.sh                                  # interaktif, daily tier
#   ./restore-openbao.sh --tier weekly                    # weekly tier'dan
#   ./restore-openbao.sh --tier monthly --yes             # onaysiz
#   ./restore-openbao.sh --snapshot /var/lib/bao-raft-snaps/raft-snapshot-*.snap
#   ./restore-openbao.sh --dry-run                        # sadece plan (hicbir sey degismez)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "${SCRIPT_DIR}/_common.sh"

TIER="daily"
SNAPSHOT_FILE=""
SNAPSHOT_ID=""
ASSUME_YES=false
DRY_RUN=false
USE_FORCE=false
# openbao/server vars ile ayni degerler; tek kaynak orada.
BAO_AGENT_SOCK="${BAO_AGENT_SOCK:-/etc/bao/agent.sock}"
ROLLBACK_DIR="${RAFT_SNAP_DIR:-/var/lib/bao-raft-snaps}"
RESTIC_ENV_DIR="${MAINT_PROJECT_NAME:+${CONF_DIR:-/etc/${MAINT_PROJECT_NAME}}/backup}"

# Raft restore ASENKRON: HTTP 204 "istek kabul edildi" demektir, "bitti"
# degil. Gercek bitis belirteci node'un yeniden unsealed olmasidir. Bu
# dongunun zaman asimi ve yoklama araligi asagidaki gibi ayarlanabilir
# (buyuk veritabanlarinda raft replay sure birkac dakikayi asabilir).
RAFT_VERIFY_TIMEOUT_SEC="${RAFT_VERIFY_TIMEOUT_SEC:-300}"
RAFT_VERIFY_POLL_SEC="${RAFT_VERIFY_POLL_SEC:-5}"
# Sifir/bos deger donguyu hic ilerletmez — felaket script'i asili kalmamali.
case "$RAFT_VERIFY_POLL_SEC" in
    ''|*[!0-9]*)  log_error "RAFT_VERIFY_POLL_SEC sayi olmali (gelen: ${RAFT_VERIFY_POLL_SEC})"; exit 1 ;;
esac
[ "$RAFT_VERIFY_POLL_SEC" -ge 1 ] || { log_error "RAFT_VERIFY_POLL_SEC >= 1 olmali (gelen: ${RAFT_VERIFY_POLL_SEC})"; exit 1; }

usage() {
    echo "Kullanim: $0 [--tier daily|weekly|monthly] [--snapshot <dosya>] [--snapshot-id <id>] [--force] [--yes] [--dry-run]"
    echo ""
    echo "  --tier         restic reposundan indirilecek kova (varsayilan: daily)"
    echo "  --snapshot     verilen yerel .snap dosyasini kullan (restic atlanir)"
    echo "  --snapshot-id  restic reposundan belirli bir snapshot ID indir"
    echo "  --force        /snapshot-force kullanir (normal restore basarisiz olursa)"
    echo "  --yes          interaktif onayi atla"
    echo "  --dry-run      hicbir sey degistirmeden plani goster"
    exit 1
}

while [[ $# -gt 0 ]]; do
    case $1 in
        --tier)        TIER="${2:?--tier deger gerekli}"; shift 2 ;;
        --snapshot)    SNAPSHOT_FILE="${2:?--snapshot deger gerekli}"; shift 2 ;;
        --snapshot-id) SNAPSHOT_ID="${2:?--snapshot-id deger gerekli}"; shift 2 ;;
        --force)       USE_FORCE=true; shift ;;
        --yes)         ASSUME_YES=true; shift ;;
        --dry-run)     DRY_RUN=true; shift ;;
        -h|--help)     usage ;;
        *)             usage ;;
    esac
done

case "$TIER" in
    daily|weekly|monthly) ;;
    *) log_error "Geçersiz tier: $TIER (daily|weekly|monthly)"; exit 1 ;;
esac

check_root

# Renk tanimlari _common.sh'de YOK (restore.sh kendi menu renklerini
# tanimlar). Bu script menu degil, duz cikti verir → set -u ile
# "unbound variable" patlamamasi icin burada tanimlanmaz, kullanilmaz.
RESTIC_ENV="/etc/${MAINT_PROJECT_NAME:-tofu-lar}/backup/openbao-${TIER}.env"
WORK_SNAP="${TEMP_DIR}/raft-restore-${TIER}.snap"
SNAPSHOT_PATH="$SNAPSHOT_FILE"

mkdir -p "$TEMP_DIR"

# ── 0) Agent socket + unsealed kontrolü ────────────────────────────────────
if [ ! -S "$BAO_AGENT_SOCK" ]; then
    log_error "bao agent socket yok: ${BAO_AGENT_SOCK}"
    log_info "Bu script CT301 (openbao-1) uzerinde calismalidir."
    log_info "Servis: systemctl status bao-raft-agent"
    exit 1
fi

log_sep
log_info "OpenBao raft snapshot geri yukleme — tier=${TIER}"
log_sep
log_info "Agent socket : ${BAO_AGENT_SOCK}"
log_info "Restic env   : ${RESTIC_ENV}"
[ -n "$SNAPSHOT_FILE" ] && log_info "Snapshot     : ${SNAPSHOT_FILE} (verilen dosya)"
log_info "Rollback     : ${ROLLBACK_DIR}/rollback-<tarih>.snap"

# ── Dry-run: hicbir sey degistirmeden plan ────────────────────────────────
if [ "$DRY_RUN" = true ]; then
    log_info "[DRY-RUN] Uygulanacak islemler:"
    echo "  1) OpenBao unsealed kontrolu"
    echo "  2) ROLLBACK snapshot al → ${ROLLBACK_DIR}/rollback-<tarih>.snap"
    if [ -n "$SNAPSHOT_FILE" ]; then
        echo "  3) Dogrula: ${SNAPSHOT_FILE}"
    else
        echo "  3) restic'ten indir: $(basename "${RESTIC_ENV}") → ${SNAPSHOT_ID:-latest} .snap"
    fi
    echo "  4) AppRole login: bao-raft-restore (read+update)"
    if [ "$USE_FORCE" = true ]; then
        echo "  5) POST /v1/sys/storage/raft/snapshot-force"
    else
        echo "  5) POST /v1/sys/storage/raft/snapshot"
    fi
    echo "  6) OpenBao verisi ${TIER} snapshot anina doner"
    log_ok "[DRY-RUN] Bitti — hicbir degisiklik yapilmadi"
    exit 0
fi

# ── 1) Onay ───────────────────────────────────────────────────────────────
if [ "$ASSUME_YES" != true ]; then
    echo ""
    echo "  UYARI: geri yukleme geri alinamaz."
    echo "  OpenBao'nun TUM verisi ${TIER} snapshot anina doner."
    echo "  Snapshot anindan sonra uretilen her sey KAYBOLUR:"
    echo "    - yeni KV sirlari / policy'ler"
    echo "    - yeni PKI sertifikalari, yeni transit key'ler"
    echo "    - degisen RBAC rolleri"
    echo ""
    echo "  Once rollback snapshot alinacak → geri donus mumkundur."
    echo ""
    read -r -p "  Emin misiniz? (Evet/Hayir): " CONFIRM
    [[ "$CONFIRM" =~ ^[Ee] ]] || { log_info "Iptal edildi"; exit 0; }
fi

# ── 2) Pre-flight: unsealed mi? ───────────────────────────────────────────
# `bao status` rc: 0=unsealed, 1=hata, 2=sealed. API tabanli restore
# sealed instance'ta calismaz.
log_info "OpenBao durum kontrol ediliyor..."
if ! command -v bao &>/dev/null; then
    log_error "bao CLI bulunamadi — durum kontrolu ve restore dogrulamasi yapilamaz."
    log_info "Paket: bao (OpenBao CLI) — bu script CT301 uzerinde calistirilir."
    exit 1
fi
BAO_STATUS_RC=0
bao_status_rc || BAO_STATUS_RC=$?
case "$BAO_STATUS_RC" in
    0) log_ok "OpenBao unsealed" ;;
    2)
        log_error "OpenBao SEALED — API tabanli restore calismaz."
        log_info "Once unseal edin: scripts/openbao-unseal/unseal.sh (3/5 pay controller'da)"
        log_info "Sealed instance, unseal edilmeden raft restore YAPILAMAZ."
        exit 1
        ;;
    *)
        log_error "OpenBao erisilemez (bao status rc=${BAO_STATUS_RC})"
        exit 1
        ;;
esac

# ── 3) ROLLBACK: mevcut durumun snapshot'ı ────────────────────────────────
mkdir -p "$ROLLBACK_DIR"
ROLLBACK_FILE="${ROLLBACK_DIR}/rollback-$(date +%Y%m%d-%H%M%S).snap"
log_info "ROLLBACK: geri yukleme ONCESI mevcut durum kaydediliyor..."
if ! BAO_ADDR="unix://${BAO_AGENT_SOCK}" bao operator raft snapshot save "$ROLLBACK_FILE"; then
    log_error "Rollback snapshot alinamadi — geri yukleme IPTAL edildi."
    log_info "Geri donus emnigi olmadan ilerlemiyoruz (bu bir güvenlik kuralidir)."
    exit 1
fi
if ! verify_raft_snapshot "$ROLLBACK_FILE"; then
    log_error "Rollback snapshot gecersiz — geri yukleme IPTAL edildi."
    exit 1
fi
log_ok "Rollback hazır: ${ROLLBACK_FILE}"
log_info "  (geri almak için: BAO_ADDR=unix://${BAO_AGENT_SOCK} bao operator raft snapshot restore ${ROLLBACK_FILE})"

# ── 4) Snapshot'ı indir (restic) veya doğrula (verilen dosya) ─────────────
if [ -n "$SNAPSHOT_FILE" ]; then
    [ -f "$SNAPSHOT_FILE" ] || { log_error "Verilen snapshot yok: $SNAPSHOT_FILE"; exit 1; }
    log_info "Verilen yerel snapshot kullaniliyor: ${SNAPSHOT_FILE}"
else
    [ -f "$RESTIC_ENV" ] || {
        log_error "Restic env dosyasi yok: ${RESTIC_ENV}"
        log_info "Bu script'i openbao-1 (CT301) uzerinde calistirin — env yalnizca orada dagitilir."
        exit 1
    }
    log_info "restic'ten snapshot indiriliyor (${TIER}, ref: ${SNAPSHOT_ID:-latest})..."
    if ! restic_fetch_latest "$RESTIC_ENV" "$WORK_SNAP" "${SNAPSHOT_ID:-latest}"; then
        log_error "restic'ten indirme basarisiz: ${RESTIC_ENV}"
        exit 1
    fi
    SNAPSHOT_PATH="$WORK_SNAP"
fi

# ── 5) Doğrula ────────────────────────────────────────────────────────────
verify_raft_snapshot "$SNAPSHOT_PATH" || exit 1
SNAP_SIZE=$(du -h "$SNAPSHOT_PATH" 2>/dev/null | cut -f1)
log_ok "Yüklenecek snapshot: ${SNAPSHOT_PATH} (${SNAP_SIZE})"

# ── 6) AppRole login (tek seferlik; token diske yazilmaz) ─────────────────
# role_id/secret_id: roles/openbao/server/tasks/backup.yml -> 0640 bao:bao
ROLE_ROLEID="/etc/bao/snap-bao-raft-restore-roleid"
ROLE_SECRETID="/etc/bao/snap-bao-raft-restore-secretid"
[ -r "$ROLE_ROLEID" ] && [ -r "$ROLE_SECRETID" ] || {
    log_error "Restore credential dosyalari yok/okunamaz:"
    log_info "  ${ROLE_ROLEID}"
    log_info "  ${ROLE_SECRETID}"
    log_info "Dagitim: ansible-playbook ansible/playbooks/openbao.yml"
    exit 1
}

# Vault/OpenBao adresi: agent socket'i login endpoint'i degil, sadece proxy.
# Login dogrudan TCP'ye gider (config.hcl'deki api_addr).
BAO_API="https://127.0.0.1:8200"
if [ -f /etc/bao/config.hcl ]; then
    _cfg_addr="$(awk -F'"' '/^api_addr/{print $2; exit}' /etc/bao/config.hcl 2>/dev/null || true)"
    [ -n "$_cfg_addr" ] && BAO_API="$_cfg_addr"
fi
unset _cfg_addr

ROLE_ID="$(tr -d ' \n' < "$ROLE_ROLEID")"
SECRET_ID="$(tr -d ' \n' < "$ROLE_SECRETID")"

log_info "AppRole login: bao-raft-restore ..."
LOGIN_RESP=$(curl -sk -X POST "${BAO_API}/v1/auth/approle/login" \
    -d "{\"role_id\":\"${ROLE_ID}\",\"secret_id\":\"${SECRET_ID}\"}" 2>/dev/null || true)
unset ROLE_ID SECRET_ID

# jq yok (bak: maintenance/ scriptlerinde jq kullanilmaz) → grep + cut
TOKEN=$(printf '%s' "$LOGIN_RESP" | grep -o '"client_token":"[^"]*"' | head -1 | cut -d'"' -f4 || true)
unset LOGIN_RESP
[ -n "$TOKEN" ] || {
    log_error "AppRole login basarisiz (token alinamadi)."
    log_info "Kontrol: policy bao-raft-restore tanimli mi? (openbao-rbac.md P15)"
    exit 1
}
log_ok "Login OK (token bellekte, diske yazilmaz)"

# ── 7) Restore ────────────────────────────────────────────────────────────
ENDPOINT="/v1/sys/storage/raft/snapshot"
[ "$USE_FORCE" = true ] && ENDPOINT="/v1/sys/storage/raft/snapshot-force"

log_sep
log_warn "YUKLENIYOR: POST ${ENDPOINT}"
log_info "Snapshot: ${SNAPSHOT_PATH}"
log_sep

HTTP_CODE=$(curl -sk -o /tmp/restore-openbao.out -w "%{http_code}" \
    -X POST -H "X-Vault-Token: ${TOKEN}" \
    --data-binary "@${SNAPSHOT_PATH}" \
    "${BAO_API}${ENDPOINT}" 2>/dev/null || echo "000")
unset TOKEN

case "$HTTP_CODE" in
    200|204)
        # 204 = "kabul edildi", "bitti" DEGIL.
        #
        # Neden ayri bir dogrulama adimi gerekiyor: restore sunucu tarafinda
        # goroutine icinde (asenkron) yazilir. API dosyayi alip bir kez
        # dogruladiktan SONRA 204 doner, gercek yazma arka planda surer.
        # Hata halinde node KENDINI SEAL EDER
        # (kaynak: internal/vault/logical_system_raft.go, handleStorageRaftSnapshotWrite
        #  — hata donusunde core.Seal() cagrilir; ayni davranis Vault
        # dokumaninda da "if the snapshot fails to verify, the node will seal
        # itself" diye belgelenmistir).
        #
        # Onceki surum burada "Tamamlandi" yazip cikiyordu. Bu, felaket
        # aninda en kotu hatayi uretiyordu: operator'a "restore basarili"
        # denirken sistem aslinda BOZUK/SEALED bir durumda kaliyordu.
        log_ok "GONDERILDI (HTTP ${HTTP_CODE}) — restore baslatildi, henuz tamamlanmadi"
        ;;
    400|422)
        log_error "Restore reddedildi (HTTP ${HTTP_CODE}). Yanit:"
        head -c 500 /tmp/restore-openbao.out 2>/dev/null; echo ""
        log_info "Zorlamak icin: --force (snapshot-force endpoint'i)"
        log_info "Geri donus: ${ROLLBACK_FILE}"
        exit 1
        ;;
    403)
        log_error "Yetkisiz (403) — policy read+update icermiyor mu?"
        exit 1
        ;;
    *)
        log_error "Beklenmeyen yanit: HTTP ${HTTP_CODE}"
        head -c 500 /tmp/restore-openbao.out 2>/dev/null; echo ""
        log_info "Geri donus: ${ROLLBACK_FILE}"
        exit 1
        ;;
esac
rm -f /tmp/restore-openbao.out

# ── 8) Doğrulama döngüsü: restore GERÇEKTEN bitti mi? ──────────────────────
# 204 yalnızca "kabul edildi" demektir. Gerçek bitiş belirteci, raft replay'in
# tamamlanıp node'un yeniden unsealed olmasıdır. Sealed ile "restore hâlâ
# sürüyor" aynı rc'yi (2) verdiği için ikisini ayırmak mümkün değildir;
# bu yüzden süre dolana kadar beklenir, kararı operatöre bırakılır.
RESTORE_STATE="dogrulanmadi"
VERIFY_RC=2
log_sep
log_info "Restore dogrulaniyor (en fazla ${RAFT_VERIFY_TIMEOUT_SEC}s, ${RAFT_VERIFY_POLL_SEC}s aralikla)..."

waited=0
while :; do
    VERIFY_RC=0
    bao_status_rc || VERIFY_RC=$?

    if [ "$VERIFY_RC" -eq 0 ]; then
        RESTORE_STATE="dogrulandi"
        break
    fi

    # Yalnizca ilk denemede sebebi yaz (dongu 5 sn'de bir tekrarlamaz).
    if [ "$waited" -eq 0 ]; then
        case "$VERIFY_RC" in
            2) log_warn "Node SEALED — restore devam ediyor olabilir, ya da basarisiz olup node seal olmus olabilir." ;;
            *) log_warn "OpenBao erisilemez (bao status rc=${VERIFY_RC}) — restore bitene kadar bekleniyor." ;;
        esac
    fi

    if [ "$waited" -ge "$RAFT_VERIFY_TIMEOUT_SEC" ]; then
        break
    fi

    sleep "$RAFT_VERIFY_POLL_SEC"
    waited=$((waited + RAFT_VERIFY_POLL_SEC))
done

# ── 9) Rapor ──────────────────────────────────────────────────────────────
log_sep
if [ "$RESTORE_STATE" = "dogrulandi" ]; then
    log_ok "DOGRULANDI — node ${waited}s sonra unsealed, raft geri yuklendi"
else
    log_error "DOGRULANMADI — ${RAFT_VERIFY_TIMEOUT_SEC}s icinde node unsealed olmadi (son rc=${VERIFY_RC})"
fi
log_sep
echo "  Yuklenen     : ${SNAPSHOT_PATH} (${TIER})"
echo "  Rollback     : ${ROLLBACK_FILE}"
echo "  HTTP         : ${HTTP_CODE} (kabul edildi)"
echo "  DOGRULAMA    : ${RESTORE_STATE} (${waited}s, son bao status rc=${VERIFY_RC})"
echo ""
echo "  Sonraki adimlar:"
echo "    1. OpenBao'yu kontrol et:  BAO_ADDR=unix://${BAO_AGENT_SOCK} bao status"
echo "    2. Gerekirse yeniden unseal: scripts/openbao-unseal/unseal.sh"
echo "    3. Smoke test: bir KV sifri oku, PKI/transit erisimini dogrula"
echo ""

if [ "$RESTORE_STATE" != "dogrulandi" ]; then
    log_warn "Raporu 'basarili' saymadan once bunu yapin:"
    log_info "  journalctl -u bao-raft-agent --since '-10 min' | grep -iE 'seal|raft|restore'"
    log_info "  'post-unseal setup complete' gorunuyorsa raft geri yukleme bitmis olabilir;"
    log_info "  node SEALED kaldiysa once unseal edin (3/5 pay controller'da)."
    log_info "  Geri almak isterseniz:"
    log_info "    BAO_ADDR=unix://${BAO_AGENT_SOCK} bao operator raft snapshot restore ${ROLLBACK_FILE}"
    log_error "Bu run FAILED olarak isaretlendi — script DOGRULANMADI ile bitti (exit 1)."
    exit 1
fi

echo "  Geri almak istersen:"
echo "    BAO_ADDR=unix://${BAO_AGENT_SOCK} \\"
echo "      bao operator raft snapshot restore ${ROLLBACK_FILE}"
echo ""
