# Trusted Software Supply Chain — Proof of Concept

Internal proof-of-concept demonstrating an end-to-end trusted software supply chain using the upstream projects behind the Red Hat Trusted Software Supply Chain portfolio.

---

## Architectural Overview

Every container image deployed to production is the output of a multi-step transformation pipeline: source code is compiled, dependencies are resolved, a container is assembled, and the result is pushed to a registry. **If any link in this chain is compromised, the entire deployment is at risk.** High-profile supply-chain attacks — SolarWinds, Log4Shell, xz-utils — have demonstrated that writing secure code is not enough: organisations must be able to **cryptographically prove** that every artefact is intact, that its dependency graph has been analysed for known vulnerabilities, and that a human-defined security policy was enforced before the artefact was signed and promoted.

This PoC implements a **Trusted Software Supply Chain** that ties together four upstream projects, each mapping directly to a Red Hat product:

| Upstream (this PoC) | Red Hat Product | Role |
|---|---|---|
| **Tekton Pipelines** | OpenShift Pipelines | Cloud-native CI/CD pipeline engine |
| **Sigstore / Cosign** | Trusted Artifact Signer (TAS) | Cryptographic signing and verification of OCI artefacts |
| **GUAC** | Trusted Profile Analyzer (TPA) | SBOM ingestion, dependency graph analysis |
| **CycloneDX + Syft + Grype** | — | SBOM generation and vulnerability scanning |

The pipeline builds a Quarkus application, generates a CycloneDX SBOM with Syft, ingests it into GUAC, and runs a **blocking security gate** powered by Grype: if any vulnerability at or above the configured severity threshold is detected (and not present in an approved allowlist), the pipeline **fails and the image is never signed**. Only when the gate passes does Cosign sign the image with a static keypair and push the signature to the registry.

```
┌──────────┐    ┌──────────┐    ┌──────────────┐    ┌────────────────┐    ┌────────────┐
│  Source   │───▸│  Build   │───▸│  SBOM + GUAC │───▸│ Security Gate  │───▸│ Sign + Push│
│  (Git)    │    │(Buildah) │    │ (Syft/GUAC)  │    │  (Grype)       │    │ (Cosign)   │
└──────────┘    └──────────┘    └──────────────┘    └───────┬────────┘    └────────────┘
                                                            │
                                                     Critical CVE?
                                                      ╱         ╲
                                                    YES          NO
                                                     ↓            ↓
                                               ❌ PIPELINE    ✅ IMAGE
                                                  HALTED       SIGNED
```

---

## Repository Layout

```
trust-supply-chain-poc/
├── quarkus-app/                          # Target Java/Quarkus application
│   ├── pom.xml                           #   Maven config (includes CycloneDX plugin)
│   ├── Dockerfile                        #   Multi-stage build on UBI9
│   └── src/
├── tekton/
│   ├── tasks/                            # Reusable Tekton Task definitions
│   │   ├── build-and-push.yaml           #   Git clone → Buildah build → registry push
│   │   ├── generate-sbom.yaml            #   Syft SBOM → cosign attest
│   │   ├── security-gate.yaml            #   Grype scan → GUAC ingest → gate
│   │   └── cosign-sign.yaml              #   Cosign sign → verify
│   └── pipelines/
│       ├── trusted-supply-chain.yaml     #   Full pipeline (build through sign)
│       ├── test-trust-chain.yaml         #   Trust-chain pipeline (SBOM → gate → sign)
│       ├── pipelinerun.yaml              #   PipelineRun manifest for kubectl
│       └── workspace-template.yaml       #   PVC template
├── guac/
│   ├── kind-config.yaml                  # Kind cluster configuration
│   └── guac-deployment.yaml              # GUAC all-in-one (GraphQL + CollectSub)
├── security/
│   └── cve-allowlist.json                # Accepted CVEs (base-image, transitive)
└── scripts/
    ├── 01-bootstrap-cluster.sh           # Create cluster, install Tekton + GUAC
    ├── 02-setup-credentials.sh           # Generate Cosign keypair, create K8s secrets
    ├── 03-run-pipeline.sh                # Launch pipeline (tkn or kubectl)
    ├── 04-verify.sh                      # Verify image signature post-pipeline
    ├── demo.sh                           # Interactive demo: fail → fix → pass → verify
    └── cleanup.sh                        # Tear down cluster and keys
```

---

## Prerequisites

| Tool | Min. version | Install (macOS) |
|---|---|---|
| `docker` / `podman` | 24+ | `brew install --cask docker` |
| `kind` | 0.23+ | `brew install kind` |
| `kubectl` | 1.28+ | `brew install kubectl` |
| `cosign` | 2.2+ | `brew install cosign` |
| `tkn` | 0.37+ | `brew install tektoncd-cli` |

A **Quay.io** account with push access to the `mronconi` namespace is required for production runs. For local testing the pipeline uses a Kind-internal registry.

---

## Quick Start

### 1. Bootstrap the cluster

```bash
git clone https://github.com/mronconis/trust-supply-chain-poc.git
cd trust-supply-chain-poc

./scripts/01-bootstrap-cluster.sh
```

This script:
- Creates a two-node Kind cluster (`trusted-supply-chain`).
- Installs Tekton Pipelines (images served from `ghcr.io/tektoncd`).
- Deploys GUAC with an in-memory `keyvalue` backend.
- Applies all Tekton Tasks and Pipelines.

Verify:

```bash
kubectl get pods -n tekton-pipelines          # controller + webhook Running
kubectl get pods -n trusted-supply-chain      # guac-graphql + guac-collectsub Running
kubectl get pipelines -n trusted-supply-chain # trusted-supply-chain, test-trust-chain
```

### 2. Configure credentials and keys

```bash
./scripts/02-setup-credentials.sh

# Or non-interactively:
QUAY_USERNAME=mronconi+robot QUAY_PASSWORD=<token> ./scripts/02-setup-credentials.sh
```

This script:
- Generates a **Cosign static keypair** (no passphrase) under `.keys/`.
- Creates the `cosign-keys` Kubernetes Secret.
- Creates the `quay-registry-secret` docker-registry Secret.

> **Security note**: `.keys/` is git-ignored. Never commit private keys.

### 3. Set up a local registry (for Kind-based testing)

```bash
docker run -d --restart=always -p 5001:5000 --network kind --name kind-registry registry:2
```

---

## Demo Walkthrough

The demo script (`scripts/demo.sh`) executes the full use case interactively. It pauses between phases so you can narrate each step to the team.

```bash
./scripts/demo.sh
```

### Phase 1 — Build the vulnerable image

The `pom.xml` ships with a deliberately pinned vulnerable dependency:

```xml
<dependency>
    <groupId>org.apache.logging.log4j</groupId>
    <artifactId>log4j-core</artifactId>
    <version>2.14.1</version>   <!-- CVE-2021-44228 — Log4Shell, CVSS 10.0 -->
</dependency>
```

The image is built and pushed to the local registry as `:vulnerable`.

### Phase 2 — Pipeline run → FAILURE

The pipeline executes three stages:

1. **SBOM Generation** — Syft scans the image and produces a CycloneDX 1.6 SBOM. The SBOM is attested to the OCI image via `cosign attest`.
2. **Security Gate** — Grype scans the SBOM. GUAC connectivity is verified. A Python evaluator partitions the results:
   - CVEs listed in `security/cve-allowlist.json` (known base-image issues) are **excluded**.
   - Remaining CVEs at or above the configured severity threshold (`critical`) are **blocking**.
   - Log4Shell (`CVE-2021-44228`) is not in the allowlist → **the gate fails**.
3. **Cosign Sign** — This stage is **never reached** because the gate exited with a non-zero status.

Expected output:

```
║  SECURITY GATE EVALUATION                                ║
║  Threshold     : CRITICAL+                               ║
║  Total CVEs    : ~500                                    ║
║  CRITICAL      : 7+   (Log4Shell variants)               ║
║  Allow-listed  : 2    (base-image CVEs)                  ║
║  Blocking      : 5+                                      ║

  BLOCKING CVEs (not in allowlist):
    ✗ CVE-2021-44228 [CRITICAL] — log4j-core:2.14.1
    ✗ CVE-2021-45046 [CRITICAL] — log4j-core:2.14.1
    ...

❌ SECURITY GATE FAILED
```

### Phase 3 — Apply the fix

The developer upgrades `log4j-core` from `2.14.1` to `2.24.3`:

```bash
# The demo script runs this automatically:
sed -i 's/2.14.1/2.24.3/' quarkus-app/pom.xml
```

The image is rebuilt and pushed as `:fixed`.

### Phase 4 — Pipeline run → SUCCESS

With Log4Shell eliminated:
- The remaining CRITICAL CVEs are in the allowlist (base-image / transitive).
- The security gate **passes**.
- Cosign **signs** the image and immediately **verifies** the signature.

```
✅ SECURITY GATE PASSED — no blocking CVEs outside allowlist

╔═══════════════════════════════════════════════════════════╗
║  COSIGN SIGN                                             ║
║  Image : kind-registry:5000/trusted-supply-chain-app:fixed@sha256:...
╚═══════════════════════════════════════════════════════════╝
✅ Image signed successfully
✅ Signature verified — the chain of trust is intact
```

### Phase 5 — Verify with cosign

```bash
# Signed image — verification PASSES
cosign verify \
  --key .keys/cosign.pub \
  --allow-insecure-registry --allow-http-registry \
  --insecure-ignore-tlog \
  localhost:5001/trusted-supply-chain-app:fixed

# Unsigned image — verification FAILS
cosign verify \
  --key .keys/cosign.pub \
  --allow-insecure-registry --allow-http-registry \
  --insecure-ignore-tlog \
  localhost:5001/trusted-supply-chain-app:vulnerable
# → Error: no matching signatures
```

**Key takeaway**: The signed image is the only one that can pass a policy-based admission controller. The vulnerable image was never signed and cannot be deployed.

---

## Security Gate Design

The gate evaluates Grype results in three steps:

1. **Load allowlist** — `security/cve-allowlist.json` contains CVE IDs accepted by the security team (typically base-image or transitive dependency issues tracked upstream).
2. **Partition results** — Each vulnerability is classified as *allowed* (in the allowlist) or *blocking* (at or above the configured severity threshold and not in the allowlist).
3. **Decide** — If any blocking CVEs remain, the task exits with code 1 and Tekton halts the pipeline. The signing stage is never executed.

```json
{
  "allowlist": [
    {
      "id": "CVE-2026-114406",
      "package": "ca-certificates",
      "reason": "UBI9 base-image CVE — tracked upstream."
    }
  ]
}
```

---

## Production Mapping

| PoC component | Production equivalent (Red Hat) |
|---|---|
| Kind cluster | OpenShift (ROSA, ARO, self-managed) |
| Tekton Pipelines | **Red Hat OpenShift Pipelines** |
| Cosign with static keys | **Trusted Artifact Signer (TAS)** — keyless signing via Sigstore Fulcio + Rekor |
| GUAC (in-memory) | **Trusted Profile Analyzer (TPA)** — persistent storage, UI, policy engine |
| Grype | Red Hat ACS / TPA vulnerability analysis |
| Quay.io SaaS | **Red Hat Quay** (on-premise or cloud) |
| CycloneDX SBOM (manual) | Integrated SBOM generation in Trusted Application Pipeline |

In production, the static keypair used here would be replaced by **keyless signing** (OIDC-backed identity via Fulcio), with every signature recorded in an immutable **transparency log** (Rekor). The CVE allowlist would be managed through a formal exception process with time-bound approvals.

---

## Manual Pipeline Execution

### Using `tkn` CLI

```bash
tkn pipeline start test-trust-chain \
  --namespace trusted-supply-chain \
  --param IMAGE="kind-registry:5000/trusted-supply-chain-app:latest" \
  --param IMAGE_DIGEST="sha256:..." \
  --param FAIL_ON_SEVERITY="critical" \
  --workspace name=shared-workspace,volumeClaimTemplateFile=tekton/pipelines/workspace-template.yaml \
  --workspace name=cosign-keys,secret=cosign-keys \
  --workspace name=dockerconfig,secret=quay-registry-secret \
  --workspace name=cve-allowlist,config=cve-allowlist \
  --showlog
```

### Using `kubectl`

```bash
kubectl create -f tekton/pipelines/pipelinerun.yaml
tkn pipelinerun logs -f -n trusted-supply-chain
```

---

## Cleanup

```bash
./scripts/cleanup.sh
```

Deletes the Kind cluster and removes the `.keys/` directory.

---

## References

- [Sigstore](https://www.sigstore.dev/) — Software signing for everyone
- [GUAC](https://guac.sh/) — Graph for Understanding Artifact Composition
- [Tekton](https://tekton.dev/) — Cloud-native CI/CD
- [CycloneDX](https://cyclonedx.org/) — SBOM standard
- [Red Hat Trusted Software Supply Chain](https://www.redhat.com/en/solutions/trusted-software-supply-chain)
- [Trusted Artifact Signer](https://docs.redhat.com/en/documentation/red_hat_trusted_artifact_signer/)
- [Trusted Profile Analyzer](https://docs.redhat.com/en/documentation/red_hat_trusted_profile_analyzer/)
