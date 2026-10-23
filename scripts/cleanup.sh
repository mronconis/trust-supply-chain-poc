#!/usr/bin/env bash
#
# cleanup.sh — Tears down the entire PoC environment
#
set -euo pipefail

KIND_CLUSTER_NAME="trusted-supply-chain"

echo "▸ Deleting Kind cluster: ${KIND_CLUSTER_NAME}"
kind delete cluster --name "${KIND_CLUSTER_NAME}" 2>/dev/null || true

echo "▸ Removing generated keys"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(dirname "${SCRIPT_DIR}")"
rm -rf "${ROOT_DIR}/.keys"

echo "✅ Cleanup complete"
