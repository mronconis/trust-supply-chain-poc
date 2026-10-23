#!/usr/bin/env bash
#
# 02-setup-credentials.sh
# Generates Cosign static keypair and creates Kubernetes secrets
# for Quay.io registry auth and Cosign signing.
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(dirname "${SCRIPT_DIR}")"
KEYS_DIR="${ROOT_DIR}/.keys"

NAMESPACE="trusted-supply-chain"

echo "╔══════════════════════════════════════════════════════════════╗"
echo "║  Trusted Supply Chain PoC — Credential Setup                ║"
echo "╚══════════════════════════════════════════════════════════════╝"

# ── Step 1: Generate Cosign keypair ──────────────────────────────
echo ""
echo "▸ [1/3] Generating Cosign static keypair"
mkdir -p "${KEYS_DIR}"

if [ -f "${KEYS_DIR}/cosign.key" ]; then
  echo "  ⚠ Keypair already exists in ${KEYS_DIR}, skipping."
else
  COSIGN_PASSWORD="" cosign generate-key-pair \
    --output-key-prefix "${KEYS_DIR}/cosign"
  echo "  ✅ Keypair generated:"
  echo "     Private key: ${KEYS_DIR}/cosign.key"
  echo "     Public key : ${KEYS_DIR}/cosign.pub"
fi

# ── Step 2: Create Cosign keys secret ────────────────────────────
echo ""
echo "▸ [2/3] Creating Kubernetes secret: cosign-keys"
kubectl create secret generic cosign-keys \
  --namespace "${NAMESPACE}" \
  --from-file=cosign.key="${KEYS_DIR}/cosign.key" \
  --from-file=cosign.pub="${KEYS_DIR}/cosign.pub" \
  --from-literal=password="" \
  --dry-run=client -o yaml | kubectl apply -f -
echo "  ✅ Secret 'cosign-keys' created"

# ── Step 3: Create Quay.io registry secret ───────────────────────
echo ""
echo "▸ [3/3] Creating Kubernetes secret: quay-registry-secret"
echo ""

if [ -z "${QUAY_USERNAME:-}" ] || [ -z "${QUAY_PASSWORD:-}" ]; then
  echo "  ℹ  Set QUAY_USERNAME and QUAY_PASSWORD environment variables"
  echo "     or enter them interactively below."
  echo ""
  if [ -z "${QUAY_USERNAME:-}" ]; then
    read -rp "  Quay.io username: " QUAY_USERNAME
  fi
  if [ -z "${QUAY_PASSWORD:-}" ]; then
    read -rsp "  Quay.io password/token: " QUAY_PASSWORD
    echo ""
  fi
fi

kubectl create secret docker-registry quay-registry-secret \
  --namespace "${NAMESPACE}" \
  --docker-server=quay.io \
  --docker-username="${QUAY_USERNAME}" \
  --docker-password="${QUAY_PASSWORD}" \
  --dry-run=client -o yaml | kubectl apply -f -

echo "  ✅ Secret 'quay-registry-secret' created"

echo ""
echo "╔══════════════════════════════════════════════════════════════╗"
echo "║  ✅ Credentials configured!                                  ║"
echo "║                                                              ║"
echo "║  Next: run ./scripts/03-run-pipeline.sh                      ║"
echo "╚══════════════════════════════════════════════════════════════╝"
