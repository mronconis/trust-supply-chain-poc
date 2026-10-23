#!/usr/bin/env bash
#
# 03-run-pipeline.sh
# Launches the Trusted Supply Chain pipeline and follows the logs.
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(dirname "${SCRIPT_DIR}")"

NAMESPACE="trusted-supply-chain"
IMAGE="${1:-quay.io/mronconi/trusted-supply-chain-app:latest}"
GIT_URL="${2:-https://github.com/mronconi/trust-supply-chain-poc.git}"
GIT_REVISION="${3:-main}"
FAIL_ON="${4:-critical}"

echo "╔══════════════════════════════════════════════════════════════╗"
echo "║  Trusted Supply Chain PoC — Pipeline Execution              ║"
echo "╚══════════════════════════════════════════════════════════════╝"
echo ""
echo "  Image          : ${IMAGE}"
echo "  Git URL        : ${GIT_URL}"
echo "  Git Revision   : ${GIT_REVISION}"
echo "  Fail on        : ${FAIL_ON}+ CVEs"
echo ""

# Check if tkn CLI is available; if not, fall back to kubectl
if command -v tkn &> /dev/null; then
  echo "▸ Starting pipeline with tkn CLI..."
  echo ""

  tkn pipeline start trusted-supply-chain \
    --namespace "${NAMESPACE}" \
    --param IMAGE="${IMAGE}" \
    --param GIT_URL="${GIT_URL}" \
    --param GIT_REVISION="${GIT_REVISION}" \
    --param FAIL_ON_SEVERITY="${FAIL_ON}" \
    --workspace name=shared-workspace,volumeClaimTemplateFile="${ROOT_DIR}/tekton/pipelines/workspace-template.yaml" \
    --workspace name=dockerconfig,secret=quay-registry-secret \
    --workspace name=cosign-keys,secret=cosign-keys \
    --use-param-defaults \
    --showlog
else
  echo "▸ tkn CLI not found — falling back to kubectl..."
  echo ""

  kubectl create -f "${ROOT_DIR}/tekton/pipelines/pipelinerun.yaml" \
    --namespace "${NAMESPACE}"

  echo ""
  echo "  ℹ  Install the tkn CLI for live log streaming:"
  echo "     brew install tektoncd-cli"
  echo ""
  echo "  Or watch logs with:"
  echo "     kubectl get pipelineruns -n ${NAMESPACE} -w"
fi

echo ""
echo "╔══════════════════════════════════════════════════════════════╗"
echo "║  Pipeline started! Watch the logs above.                    ║"
echo "╚══════════════════════════════════════════════════════════════╝"
