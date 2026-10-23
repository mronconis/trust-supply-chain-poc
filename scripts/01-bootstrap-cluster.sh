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
echo "▸ [1/6] Creating Kind cluster: ${KIND_CLUSTER_NAME}"
if kind get clusters 2>/dev/null | grep -q "${KIND_CLUSTER_NAME}"; then
  echo "  ⚠ Cluster '${KIND_CLUSTER_NAME}' already exists, skipping creation."
else
  kind create cluster --config "${ROOT_DIR}/guac/kind-config.yaml"
  echo "  ✅ Kind cluster created"
fi

kubectl cluster-info --context "kind-${KIND_CLUSTER_NAME}"

# ── Step 2: Create namespace ─────────────────────────────────────
echo ""
echo "▸ [2/6] Creating namespace: ${NAMESPACE}"
kubectl create namespace "${NAMESPACE}" --dry-run=client -o yaml | kubectl apply -f -

# ── Step 3: Install Tekton Pipelines ─────────────────────────────
echo ""
echo "▸ [3/6] Installing Tekton Pipelines (${TEKTON_VERSION})"
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
echo "▸ [4/6] Deploying GUAC (upstream Trusted Profile Analyzer)"
kubectl apply -f "${ROOT_DIR}/guac/guac-deployment.yaml"

echo "  ⏳ Waiting for GUAC to be ready..."
kubectl wait --for=condition=Available \
  deployment/guac-graphql \
  -n "${NAMESPACE}" \
  --timeout=120s || echo "  ⚠ GUAC may need more time — continuing..."

echo "  ✅ GUAC deployed"

# ── Step 5: Deploy GUAC Visualizer ────────────────────────────────
echo ""
echo "▸ [5/6] Deploying GUAC Visualizer"
kubectl apply -f "${ROOT_DIR}/guac/guac-visualizer.yaml"

echo "  ⏳ Waiting for GUAC Visualizer to be ready..."
kubectl wait --for=condition=Available \
  deployment/guac-visualizer \
  -n "${NAMESPACE}" \
  --timeout=120s || echo "  ⚠ Visualizer may need more time — continuing..."

echo "  ✅ GUAC Visualizer deployed (port-forward with: kubectl port-forward -n ${NAMESPACE} svc/guac-visualizer 3000:3000)"

# ── Step 6: Install Tekton Tasks and Pipeline ─────────────────────
echo ""
echo "▸ [6/6] Installing Tekton Tasks and Pipeline"
kubectl apply -f "${ROOT_DIR}/tekton/tasks/"
kubectl apply -f "${ROOT_DIR}/tekton/pipelines/trusted-supply-chain-quay.yaml"

echo "  ✅ Tasks and Pipeline installed"

echo ""
echo "╔══════════════════════════════════════════════════════════════╗"
echo "║  ✅ Bootstrap complete!                                      ║"
echo "║                                                              ║"
echo "║  Next: run ./scripts/02-setup-credentials.sh                 ║"
echo "╚══════════════════════════════════════════════════════════════╝"
