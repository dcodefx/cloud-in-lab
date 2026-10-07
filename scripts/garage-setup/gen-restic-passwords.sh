#!/usr/bin/env bash
# gen-restic-passwords.sh — kova (repo) basina restic sifresi uretir
#
# Vault BU ASAMADA kullanilmiyor — proje konvansiyonu izlenir:
#   secret'lar ansible/outputs/ altinda 0600 duz dosya (bkz.
#   ansible/outputs/openbao/openbao-credentials.yml).
#
# Urettigi dosyalar: ansible/outputs/garage-backups/ct-<ctid>/restic-<job>.pw (0600)
# Role (roles/maintenance) bu dosyalari okuyup hedeflere 0600 dagitir.
# Alt dizin CT bazlidir: her backup garaji kendi sifrelerini tasir, yeni
# kurulum eskisinin sifreleriyle sessizce eslesmez.
#
# KULLANIM:  ./gen-restic-passwords.sh --ct-id <id>   (sadece chef.sh cagirir)
#
# ONEMLI:
#   * Job listesi roles/maintenance/defaults/main.yml `maintenance_jobs`'tan
#     OKUNUR (tek kaynak — elle liste tutulmaz).
#   * Idempotent-guvenli: mevcut sifre ASLA uzerine yazilmaz — kayip restic
#     repo sifresi = o kovadaki yedeklerin TAMAMI kayip demektir.
#   * Uretimden sonra kopyalari password manager'a alin (unseal-key kurali
#     ile ayni kanal disiplini, master-design §10).
#   * Ileride ansible-vault'a gecilirse: roles/maintenance yalnizca bu
#     dosyalari okuyan lookup'i degistirir, baska sey degismez.

set -euo pipefail

CT_ID=""
while [ $# -gt 0 ]; do
    case "$1" in
        --ct-id) CT_ID="${2:?--ct-id bir CT ID gerektirir}"; shift 2 ;;
        *) echo "[HATA] bilinmeyen arguman: $1 (kullanim: $0 --ct-id <id>)" >&2; exit 1 ;;
    esac
done
[[ "$CT_ID" =~ ^[0-9]+$ ]] || { echo "[HATA] --ct-id zorunlu ve sayisal olmali (bu script sadece chef.sh'ten cagrilir)" >&2; exit 1; }

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
DEFAULTS="${REPO_DIR}/ansible/roles/maintenance/defaults/main.yml"
OUT_DIR="${REPO_DIR}/ansible/outputs/garage-backups/ct-${CT_ID}"

# Job adlari — tek kaynak: defaults/main.yml maintenance_jobs (yalniz restic:
# true olanlar; vm-disk restic disi sifre istemez). Elle liste tutulmaz.
JOBS="$(python3 - "$DEFAULTS" <<'PYEOF'
import sys, yaml
d = yaml.safe_load(open(sys.argv[1]))
print(" ".join(k for k, v in d["maintenance_jobs"].items() if v.get("restic")))
PYEOF
)" || { echo "[HATA] maintenance_jobs okunamadi: $DEFAULTS (python3 + pyyaml gerekli)" >&2; exit 1; }

mkdir -p "$OUT_DIR"

echo "Restic repo sifreleri -> ${OUT_DIR}/restic-<job>.pw"
echo "Joblar: $JOBS"
echo ""
for j in $JOBS; do
    f="${OUT_DIR}/restic-${j}.pw"
    if [ -s "$f" ]; then
        echo "[SKIP] restic-${j}.pw zaten var (uzerine yazilmaz)"
        continue
    fi
    umask 077
    openssl rand -base64 32 > "$f"
    chmod 600 "$f"
    echo "[OK]   restic-${j}.pw uretildi (0600)"
done

echo ""
echo "UYARI: Restic repo sifresi kaybolursa o kovadaki yedekler KURTARILAMAZ."
echo "Kopyalarini password manager'a al:"
echo "  cat ${OUT_DIR}/restic-*.pw"
