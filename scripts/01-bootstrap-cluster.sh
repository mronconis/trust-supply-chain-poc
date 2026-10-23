#!/usr/bin/env bash
#
# 01-bootstrap-cluster.sh
# Creates Kind cluster and installs Tekton Pipelines + GUAC
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(dirname "${SCRIPT_DIR}")"

TEKTON_VERSION="latest"
KIND_CLUSTER_NAME="trusted-supply-chain"
NAMESPACE="trusted-supply-chain"

echo "╔══════════════════════════════════════════════════════════════╗"
echo "║  Trusted Supply Chain PoC — Bootstrap                       ║"
echo "╚══════════════════════════════════════════════════════════════╝"

# ── Pre-flight checks ────────────────────────────────────────────
for cmd in kind kubectl cosign; do
  if ! command -v "${cmd}" &> /dev/null; then
    echo "❌ '${cmd}' not found. Please install it first."
    exit 1
  fi
done

# ── Step 1: Create Kind cluster ──────────────────────────────────
echo ""
echo "▸ [1/7] Creating Kind cluster: ${KIND_CLUSTER_NAME}"
if kind get clusters 2>/dev/null | grep -q "${KIND_CLUSTER_NAME}"; then
  echo "  ⚠ Cluster '${KIND_CLUSTER_NAME}' already exists, skipping creation."
else
  kind create cluster --config "${ROOT_DIR}/guac/kind-config.yaml"
  echo "  ✅ Kind cluster created"
fi

kubectl cluster-info --context "kind-${KIND_CLUSTER_NAME}"

# ── Step 2: Create namespace ─────────────────────────────────────
echo ""
echo "▸ [2/7] Creating namespace: ${NAMESPACE}"
kubectl create namespace "${NAMESPACE}" --dry-run=client -o yaml | kubectl apply -f -

# ── Step 3: Install Tekton Pipelines ─────────────────────────────
echo ""
echo "▸ [3/7] Installing Tekton Pipelines (${TEKTON_VERSION})"
kubectl apply --filename "https://storage.googleapis.com/tekton-releases/pipeline/${TEKTON_VERSION}/release.yaml"

echo "  ⏳ Waiting for Tekton Pipelines to be ready..."
kubectl wait --for=condition=Available \
  deployment/tekton-pipelines-controller \
  -n tekton-pipelines \
  --timeout=120s

kubectl wait --for=condition=Available \
  deployment/tekton-pipelines-webhook \
  -n tekton-pipelines \
  --timeout=120s

echo "  ✅ Tekton Pipelines installed and ready"

# ── Step 4: Deploy GUAC ──────────────────────────────────────────
echo ""
echo "▸ [4/7] Deploying GUAC (upstream Trusted Profile Analyzer)"
kubectl apply -f "${ROOT_DIR}/guac/guac-deployment.yaml"

echo "  ⏳ Waiting for GUAC to be ready..."
kubectl wait --for=condition=Available \
  deployment/guac-graphql \
  -n "${NAMESPACE}" \
  --timeout=120s || echo "  ⚠ GUAC may need more time — continuing..."

echo "  ✅ GUAC deployed"

# ── Step 5: Deploy GUAC Visualizer ────────────────────────────────
echo ""
echo "▸ [5/7] Deploying GUAC Visualizer"
kubectl apply -f "${ROOT_DIR}/guac/guac-visualizer.yaml"

echo "  ⏳ Waiting for GUAC Visualizer to be ready..."
kubectl wait --for=condition=Available \
  deployment/guac-visualizer \
  -n "${NAMESPACE}" \
  --timeout=120s || echo "  ⚠ Visualizer may need more time — continuing..."

echo "  ✅ GUAC Visualizer deployed (port-forward with: kubectl port-forward -n ${NAMESPACE} svc/guac-visualizer 3000:3000)"

# ── Step 6: Install Tekton Tasks and Pipeline ─────────────────────
echo ""
echo "▸ [6/7] Installing Tekton Tasks and Pipeline"
kubectl apply -f "${ROOT_DIR}/tekton/tasks/"
kubectl apply -f "${ROOT_DIR}/tekton/pipelines/trusted-supply-chain-quay.yaml"

# ── Step 7: Setup Credentials ─────────────────────────────────────
echo ""
echo "▸ [7/7] Setting up credentials"
echo "  ℹ  This step was previously done by ./scripts/02-setup-credentials.sh"

# ── Load credentials from .env ───────────────────────────────────
ENV_FILE="${ROOT_DIR}/.env"
KEYS_DIR="${ROOT_DIR}/.keys"

if [ -f "${ENV_FILE}" ]; then
  # shellcheck disable=SC1090
  source "${ENV_FILE}"
  echo "  ℹ  Loaded credentials from ${ENV_FILE}"
fi

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

# ── Create Cosign keys secret ────────────────────────────
echo ""
echo "▸ [2/3] Creating Kubernetes secret: cosign-keys"
kubectl create secret generic cosign-keys \
  --namespace "${NAMESPACE}" \
  --from-file=cosign.key="${KEYS_DIR}/cosign.key" \
  --from-file=cosign.pub="${KEYS_DIR}/cosign.pub" \
  --from-literal=password="" \
  --dry-run=client -o yaml | kubectl apply -f -
echo "  ✅ Secret 'cosign-keys' created"

# ── Create Quay.io registry secret ───────────────────────
echo ""
echo "▸ [3/3] Creating Kubernetes secret: quay-registry-secret"
echo ""

QUAY_PASSWORD="${QUAY_SECRET:-${QUAY_PASSWORD:-}}"

if [ -z "${QUAY_USERNAME:-}" ] || [ -z "${QUAY_PASSWORD:-}" ]; then
  echo "  ℹ  Set QUAY_USERNAME and QUAY_SECRET in .env (project root)"
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
echo "║  ✅ Bootstrap complete!                                      ║"
echo "║                                                              ║"
echo "║  Next: run ./scripts/03-run-pipeline.sh                      ║"
echo "╚══════════════════════════════════════════════════════════════╝"
