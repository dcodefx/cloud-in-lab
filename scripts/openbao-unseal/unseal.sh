#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CREDENTIALS="${SCRIPT_DIR}/credentials.txt"

log_info()  { echo "[INFO]  $*"; }
log_warn()  { echo "[WARN]  $*" >&2; }
log_error() { echo "[ERROR] $*" >&2; }

if [ ! -f "$CREDENTIALS" ]; then
  log_error "credentials.txt bulunamadi: $CREDENTIALS"
  exit 1
fi

source "$CREDENTIALS"

OPENBAO_ADDR="https://${OPENBAO_HOST}:${OPENBAO_PORT}"

if [ ${#UNSEAL_KEYS[@]} -lt "$UNSEAL_THRESHOLD" ]; then
  log_error "Yetersiz unseal key: ${#UNSEAL_KEYS[@]} mevcut, $UNSEAL_THRESHOLD gerekli"
  exit 1
fi

health_code() {
  curl -sk -o /dev/null -w "%{http_code}" "${OPENBAO_ADDR}/v1/sys/health" 2>/dev/null || echo "000"
}

log_info "OpenBao health kontrol ediliyor: ${OPENBAO_ADDR}"
HTTP_CODE=$(health_code)

case "$HTTP_CODE" in
  200|429|472|473)
    log_info "OpenBao zaten unsealed (HTTP $HTTP_CODE)"
    exit 0
    ;;
  503)
    log_info "OpenBao sealed durumda — unseal baslatiliyor..."
    ;;
  *)
    log_error "OpenBao erisilemez (HTTP $HTTP_CODE). LXC calisiyor mu?"
    exit 1
    ;;
esac

for (( i=0; i<UNSEAL_THRESHOLD; i++ )); do
  KEY="${UNSEAL_KEYS[$i]}"
  log_info "Unseal key $((i+1))/$UNSEAL_THRESHOLD gonderiliyor..."

  RESPONSE=$(curl -sk -w "\n%{http_code}" -X POST \
    "${OPENBAO_ADDR}/v1/sys/unseal" \
    -H "Content-Type: application/json" \
    -d "{\"key\": \"$KEY\"}" 2>/dev/null)

  HTTP_BODY=$(echo "$RESPONSE" | sed '$d')
  HTTP_CODE=$(echo "$RESPONSE" | tail -1)

  if [ "$HTTP_CODE" != "200" ]; then
    log_error "Unseal key $((i+1)) basarisiz (HTTP $HTTP_CODE)"
    log_error "Yanit: $HTTP_BODY"
    exit 1
  fi

  SEALED=$(echo "$HTTP_BODY" | grep -o '"sealed":[^,}]*' | cut -d: -f2)

  if [ "$SEALED" = "false" ]; then
    log_info "OpenBao basariyla unseal edildi!"
    exit 0
  fi
done

log_warn "Threshold kadar key gonderildi ama sealed hala false degil — kontrol edin"
exit 1
