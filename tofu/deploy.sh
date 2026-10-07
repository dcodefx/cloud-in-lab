#!/bin/bash
# tofu-lar Deploy Script
# Kullanim:
#   ./deploy.sh dev k8s-cluster
#   ./deploy.sh prod databases
#   ./deploy.sh dev efk
#   ./deploy.sh dev floci
#   ./deploy.sh dev openbao

set -e

STACK=$2
ENV=$1

if [ -z "$STACK" ] || [ -z "$ENV" ]; then
  echo "Kullanim: $0 <env> <stack>"
  echo "  env:   dev, prod"
  echo "  stack:"
  for dir in stacks/*/; do
    echo "    $(basename "$dir")"
  done
  exit 1
fi

BACKEND_FILE="backends/${STACK}.backend.tfbackend"
COMMON_VARS="environments/${ENV}/common.tfvars"
STACK_VARS="environments/${ENV}/${STACK}.tfvars"

if [ ! -f "$BACKEND_FILE" ]; then
  echo "HATA: Backend config bulunamadi: $BACKEND_FILE"
  echo "Once backends/${STACK}.backend.tfbackend dosyasini olustur."
  exit 1
fi

if [ ! -f "$COMMON_VARS" ]; then
  echo "HATA: Ortak tfvars bulunamadi: $COMMON_VARS"
  exit 1
fi

if [ ! -f "$STACK_VARS" ]; then
  echo "HATA: Stack tfvars bulunamadi: $STACK_VARS"
  exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

cd "$SCRIPT_DIR/stacks/$STACK"

echo "=== $ENV / $STACK ==="
echo "1/2: Initializing backend..."
tofu init -backend-config="$SCRIPT_DIR/$BACKEND_FILE"

echo "2/2: Applying..."
tofu apply -var-file="$SCRIPT_DIR/$COMMON_VARS" -var-file="$SCRIPT_DIR/$STACK_VARS"

echo "=== Done ==="
