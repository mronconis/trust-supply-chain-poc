#!/usr/bin/env bash
#
# 02-run-pipeline.sh
# Launches the Trusted Supply Chain pipeline and follows the logs.
#
set -euo pipefail

# Function to print usage
print_usage() {
  echo "Usage: $0 [OPTIONS]"
  echo ""
  echo "Options:"
  echo "  --image IMAGE              Container image name (default: quay.io/mronconi/trusted-supply-chain-app:latest)"
  echo "  --git-url URL              Git repository URL (default: https://github.com/mronconis/trust-supply-chain-poc.git)"
  echo "  --revision REVISION        Git revision (default: main)"
  echo "  --context CONTEXT          Application context path (default: quarkus-app)"
  echo "  --fail-on SEVERITY         Fail on severity threshold (default: critical)"
  echo "  -h, --help                 Show this help message"
  echo ""
  echo "Examples:"
  echo "  $0 --revision \"feature/new-feature\""
  echo "  $0 --image \"custom/image:tag\" --revision \"main\" --fail-on \"high\""
  echo "  $0 --help"
}

# Initialize default values
IMAGE="quay.io/mronconi/trusted-supply-chain-app:latest"
GIT_URL="https://github.com/mronconis/trust-supply-chain-poc.git"
GIT_REVISION="main"
APP_CONTEXT="quarkus-app"
FAIL_ON="critical"

# Parse command line arguments
while [[ $# -gt 0 ]]; do
  case $1 in
    --image)
      IMAGE="$2"
      shift 2
      ;;
    --git-url)
      GIT_URL="$2"
      shift 2
      ;;
    --revision)
      GIT_REVISION="$2"
      shift 2
      ;;
    --context)
      APP_CONTEXT="$2"
      shift 2
      ;;
    --fail-on)
      FAIL_ON="$2"
      shift 2
      ;;
    -h|--help)
      print_usage
      exit 0
      ;;
    *)
      echo "Unknown option: $1"
      print_usage
      exit 1
      ;;
  esac
done

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(dirname "${SCRIPT_DIR}")"

NAMESPACE="trusted-supply-chain"

echo "╔══════════════════════════════════════════════════════════════╗"
echo "║  Trusted Supply Chain PoC — Pipeline Execution              ║"
echo "╚══════════════════════════════════════════════════════════════╝"
echo ""
echo "  Image          : ${IMAGE}"
echo "  Git URL        : ${GIT_URL}"
echo "  Git Revision   : ${GIT_REVISION}"
echo "  App Context    : ${APP_CONTEXT}"
echo "  Fail on        : ${FAIL_ON}+ CVEs"
echo ""

# Ensure CVE allowlist ConfigMap exists
kubectl create configmap cve-allowlist \
  --namespace "${NAMESPACE}" \
  --from-file=cve-allowlist.json="${ROOT_DIR}/security/cve-allowlist.json" \
  --dry-run=client -o yaml | kubectl apply -f - 2>/dev/null
echo "▸ CVE allowlist ConfigMap applied"
echo ""

# Check if tkn CLI is available; if not, fall back to kubectl
if command -v tkn &> /dev/null; then
  echo "▸ Starting pipeline with tkn CLI..."
  echo ""

  tkn pipeline start trusted-supply-chain-quay \
    --namespace "${NAMESPACE}" \
    --param IMAGE="${IMAGE}" \
    --param GIT_URL="${GIT_URL}" \
    --param GIT_REVISION="${GIT_REVISION}" \
    --param APP_CONTEXT="${APP_CONTEXT}" \
    --param FAIL_ON_SEVERITY="${FAIL_ON}" \
    --workspace name=shared-workspace,volumeClaimTemplateFile="${ROOT_DIR}/tekton/pipelines/workspace-template.yaml" \
    --workspace name=cosign-keys,secret=cosign-keys \
    --workspace name=dockerconfig,secret=quay-registry-secret \
    --workspace name=cve-allowlist,config=cve-allowlist \
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
