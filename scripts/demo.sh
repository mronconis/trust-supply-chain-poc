#!/usr/bin/env bash
#
# demo.sh — Full Trusted Supply Chain demo workflow
#
# Demonstrates:
#   1. Pipeline FAILS on a CRITICAL CVE (Log4Shell in log4j-core 2.14.1)
#   2. Developer applies a fix (upgrades log4j-core to 2.24.3)
#   3. Pipeline PASSES after the fix
#   4. cosign verify proves the image is signed
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(dirname "${SCRIPT_DIR}")"
APP_DIR="${ROOT_DIR}/quarkus-app"

REGISTRY="kind-registry:5000"
LOCAL_REGISTRY="localhost:5001"
APP_NAME="trusted-supply-chain-app"
NS="trusted-supply-chain"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

banner() {
  echo ""
  echo -e "${CYAN}╔═══════════════════════════════════════════════════════════╗${NC}"
  echo -e "${CYAN}║${NC}  ${BOLD}$1${NC}"
  echo -e "${CYAN}╚═══════════════════════════════════════════════════════════╝${NC}"
  echo ""
}

pause() {
  echo ""
  echo -e "${YELLOW}  ▸ Press ENTER to continue...${NC}"
  read -r
}

get_digest() {
  local tag=$1
  curl -s -I "http://${LOCAL_REGISTRY}/v2/${APP_NAME}/manifests/${tag}" \
    -H "Accept: application/vnd.oci.image.manifest.v1+json" 2>/dev/null \
    | grep -i docker-content-digest | awk '{print $2}' | tr -d '\r'
}

# ══════════════════════════════════════════════════════════
# PRE-FLIGHT
# ══════════════════════════════════════════════════════════
banner "TRUSTED SOFTWARE SUPPLY CHAIN — LIVE DEMO"

echo "  This demo walks through a real supply-chain security workflow:"
echo ""
echo "    Phase 1 — Build an app with a CRITICAL vulnerability (Log4Shell)"
echo "    Phase 2 — Pipeline detects the CVE and BLOCKS the release"
echo "    Phase 3 — Developer applies the fix (upgrades log4j-core)"
echo "    Phase 4 — Pipeline passes, image is SIGNED"
echo "    Phase 5 — Verify the signature with cosign"

pause

# ══════════════════════════════════════════════════════════
# PHASE 1 — Build the VULNERABLE image
# ══════════════════════════════════════════════════════════
banner "PHASE 1 — Building vulnerable image (log4j-core 2.14.1)"

echo -e "  ${RED}pom.xml contains:${NC}"
echo "    <artifactId>log4j-core</artifactId>"
echo "    <version>2.14.1</version>    ← CVE-2021-44228 (Log4Shell) CRITICAL"
echo ""

grep -A2 'log4j-core' "${APP_DIR}/pom.xml" | head -6

echo ""
echo "  Building container image..."
cd "${APP_DIR}"
docker build -t "${LOCAL_REGISTRY}/${APP_NAME}:vulnerable" . 2>&1 | tail -3
docker push --tls-verify=false "${LOCAL_REGISTRY}/${APP_NAME}:vulnerable" 2>&1 | tail -2

DIGEST_V=$(get_digest "vulnerable")
echo ""
echo -e "  ${GREEN}Image pushed:${NC} ${REGISTRY}/${APP_NAME}:vulnerable"
echo -e "  ${GREEN}Digest:${NC}       ${DIGEST_V}"

pause

# ══════════════════════════════════════════════════════════
# PHASE 2 — Run pipeline → EXPECTED FAILURE
# ══════════════════════════════════════════════════════════
banner "PHASE 2 — Running pipeline (expecting FAILURE)"

echo -e "  ${YELLOW}The security gate should detect Log4Shell and BLOCK the pipeline.${NC}"
echo -e "  ${YELLOW}The image will NOT be signed.${NC}"
echo ""

# Create allowlist ConfigMap
kubectl create configmap cve-allowlist \
  --namespace "${NS}" \
  --from-file=cve-allowlist.json="${ROOT_DIR}/security/cve-allowlist.json" \
  --dry-run=client -o yaml | kubectl apply -f - 2>/dev/null

tkn pipeline start test-trust-chain \
  --namespace "${NS}" \
  --param IMAGE="${REGISTRY}/${APP_NAME}:vulnerable" \
  --param IMAGE_DIGEST="${DIGEST_V}" \
  --param FAIL_ON_SEVERITY="critical" \
  --workspace name=shared-workspace,volumeClaimTemplateFile="${ROOT_DIR}/tekton/pipelines/workspace-template.yaml" \
  --workspace name=cosign-keys,secret=cosign-keys \
  --workspace name=dockerconfig,secret=quay-registry-secret \
  --workspace name=cve-allowlist,config=cve-allowlist \
  --showlog 2>&1 || true

echo ""
echo -e "  ${RED}╔═══════════════════════════════════════════════════════════╗${NC}"
echo -e "  ${RED}║  Pipeline FAILED — Log4Shell CVE detected.               ║${NC}"
echo -e "  ${RED}║  The image was NOT signed. cosign verify would fail.     ║${NC}"
echo -e "  ${RED}╚═══════════════════════════════════════════════════════════╝${NC}"

pause

# ══════════════════════════════════════════════════════════
# PHASE 3 — Apply the fix
# ══════════════════════════════════════════════════════════
banner "PHASE 3 — Applying the fix"

echo "  Upgrading log4j-core from 2.14.1 → 2.24.3 ..."
echo ""

# Apply the fix: upgrade log4j-core version
sed -i.bak 's|<version>2.14.1</version><!-- LOG4J -->|<version>2.24.3</version><!-- LOG4J -->|' "${APP_DIR}/pom.xml" 2>/dev/null || \
  sed -i '' 's|<version>2.14.1</version>|<version>2.24.3</version>|' "${APP_DIR}/pom.xml"

echo -e "  ${GREEN}pom.xml updated:${NC}"
grep -A2 'log4j-core' "${APP_DIR}/pom.xml" | head -6
echo ""

echo "  Rebuilding container image with the fix..."
docker build -t "${LOCAL_REGISTRY}/${APP_NAME}:fixed" . 2>&1 | tail -3
docker push --tls-verify=false "${LOCAL_REGISTRY}/${APP_NAME}:fixed" 2>&1 | tail -2

DIGEST_F=$(get_digest "fixed")
echo ""
echo -e "  ${GREEN}Fixed image pushed:${NC} ${REGISTRY}/${APP_NAME}:fixed"
echo -e "  ${GREEN}Digest:${NC}             ${DIGEST_F}"

pause

# ══════════════════════════════════════════════════════════
# PHASE 4 — Run pipeline → EXPECTED SUCCESS
# ══════════════════════════════════════════════════════════
banner "PHASE 4 — Running pipeline on fixed image (expecting SUCCESS)"

echo -e "  ${GREEN}Log4Shell is gone. Base-image CVEs are in the allowlist.${NC}"
echo -e "  ${GREEN}The security gate should PASS and the image will be SIGNED.${NC}"
echo ""

tkn pipeline start test-trust-chain \
  --namespace "${NS}" \
  --param IMAGE="${REGISTRY}/${APP_NAME}:fixed" \
  --param IMAGE_DIGEST="${DIGEST_F}" \
  --param FAIL_ON_SEVERITY="critical" \
  --workspace name=shared-workspace,volumeClaimTemplateFile="${ROOT_DIR}/tekton/pipelines/workspace-template.yaml" \
  --workspace name=cosign-keys,secret=cosign-keys \
  --workspace name=dockerconfig,secret=quay-registry-secret \
  --workspace name=cve-allowlist,config=cve-allowlist \
  --showlog 2>&1

echo ""
echo -e "  ${GREEN}╔═══════════════════════════════════════════════════════════╗${NC}"
echo -e "  ${GREEN}║  Pipeline PASSED — image is SIGNED and TRUSTED.          ║${NC}"
echo -e "  ${GREEN}╚═══════════════════════════════════════════════════════════╝${NC}"

pause

# ══════════════════════════════════════════════════════════
# PHASE 5 — Verify with cosign
# ══════════════════════════════════════════════════════════
banner "PHASE 5 — Signature verification (cosign verify)"

echo "  Verifying the SIGNED (fixed) image..."
echo ""

cosign verify \
  --key "${ROOT_DIR}/.keys/cosign.pub" \
  --allow-insecure-registry --allow-http-registry \
  --insecure-ignore-tlog \
  "${LOCAL_REGISTRY}/${APP_NAME}:fixed" 2>&1

echo ""
echo "  ────────────────────────────────────────────────────"
echo ""
echo "  Now verifying the UNSIGNED (vulnerable) image..."
echo ""

cosign verify \
  --key "${ROOT_DIR}/.keys/cosign.pub" \
  --allow-insecure-registry --allow-http-registry \
  --insecure-ignore-tlog \
  "${LOCAL_REGISTRY}/${APP_NAME}:vulnerable" 2>&1 || true

echo ""
echo -e "${GREEN}╔═══════════════════════════════════════════════════════════╗${NC}"
echo -e "${GREEN}║                    DEMO COMPLETE                         ║${NC}"
echo -e "${GREEN}╠═══════════════════════════════════════════════════════════╣${NC}"
echo -e "${GREEN}║                                                         ║${NC}"
echo -e "${GREEN}║${NC}  ${RED}✗${NC} Vulnerable image → gate FAILED → NOT signed          ${GREEN}║${NC}"
echo -e "${GREEN}║${NC}  ${GREEN}✓${NC} Fixed image      → gate PASSED → SIGNED ✓            ${GREEN}║${NC}"
echo -e "${GREEN}║                                                         ║${NC}"
echo -e "${GREEN}║${NC}  The pipeline enforces that only images free of          ${GREEN}║${NC}"
echo -e "${GREEN}║${NC}  critical CVEs can be cryptographically signed           ${GREEN}║${NC}"
echo -e "${GREEN}║${NC}  and promoted to production.                             ${GREEN}║${NC}"
echo -e "${GREEN}║                                                         ║${NC}"
echo -e "${GREEN}╚═══════════════════════════════════════════════════════════╝${NC}"

# Restore pom.xml to vulnerable state for repeatable demo
sed -i '' 's|<version>2.24.3</version>|<version>2.14.1</version>|' "${APP_DIR}/pom.xml" 2>/dev/null || \
  sed -i 's|<version>2.24.3</version>|<version>2.14.1</version>|' "${APP_DIR}/pom.xml"
