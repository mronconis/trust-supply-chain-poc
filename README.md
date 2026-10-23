# 🔒 Trusted Software Supply Chain — Proof of Concept

> **PoC interna** per dimostrare al team il funzionamento di una supply chain software sicura
> usando i prodotti upstream dell'ecosistema Red Hat.

---

## 1. Pitch Architetturale

### Il problema

Ogni container image che deployiamo in produzione è il risultato di una catena di trasformazioni: dal codice sorgente, alle dipendenze, al build, fino al push sul registry. **Se un qualsiasi anello di questa catena viene compromesso, l'intera applicazione è a rischio.** Gli attacchi alla supply chain software (SolarWinds, Log4Shell, xz-utils) hanno dimostrato che non basta scrivere codice sicuro: serve **dimostrare crittograficamente** che ogni artefatto è integro, verificato e privo di vulnerabilità note critiche.

### La soluzione

Questa PoC implementa una **Trusted Software Supply Chain** end-to-end usando i progetti upstream di tre prodotti Red Hat:

| Upstream (PoC) | Prodotto Red Hat | Ruolo |
|---|---|---|
| **Tekton Pipelines** | Red Hat OpenShift Pipelines | Pipeline CI/CD cloud-native |
| **Sigstore / Cosign** | Red Hat Trusted Artifact Signer (TAS) | Firma crittografica degli artefatti OCI |
| **GUAC** | Red Hat Trusted Profile Analyzer (TPA) | Ingestion e analisi della SBOM, grafo delle dipendenze |
| **CycloneDX + Grype** | — | Generazione SBOM e vulnerability scanning |

La pipeline costruisce l'immagine, genera una SBOM (Software Bill of Materials) in formato CycloneDX, la invia a GUAC per l'analisi del grafo delle dipendenze, e applica un **Security Gate bloccante**: se vengono rilevate CVE con severità **CRITICAL**, la pipeline fallisce e l'immagine **non viene firmata**. Solo se il gate viene superato, l'immagine viene firmata con Cosign e pushata su Quay.io con una firma verificabile da chiunque possieda la chiave pubblica.

```
┌─────────┐    ┌──────────┐    ┌──────────────┐    ┌────────────────┐    ┌────────────┐
│  Source  │───▸│  Build   │───▸│  SBOM + GUAC │───▸│ Security Gate  │───▸│ Sign + Push│
│  (Git)   │    │ (Buildah)│    │  (Syft/GUAC) │    │   (Grype)      │    │  (Cosign)  │
└─────────┘    └──────────┘    └──────────────┘    └───────┬────────┘    └────────────┘
                                                           │
                                                    CRITICAL CVE?
                                                     │          │
                                                    YES         NO
                                                     │          │
                                                     ▼          ▼
                                               ❌ PIPELINE   ✅ IMAGE
                                                  FAILS       SIGNED
```

---

## 2. Struttura del Repository

```
trust-supply-chain-poc/
├── README.md                          # Questo file
├── quarkus-app/                       # App Quarkus target
│   ├── pom.xml
│   ├── Dockerfile
│   └── src/main/java/...
├── tekton/
│   ├── tasks/
│   │   ├── build-and-push.yaml        # Task: clone + build + push
│   │   ├── generate-sbom.yaml         # Task: Syft SBOM + cosign attest
│   │   ├── security-gate.yaml         # Task: Grype scan + GUAC ingest + gate
│   │   └── cosign-sign.yaml           # Task: cosign sign + verify
│   └── pipelines/
│       ├── trusted-supply-chain.yaml  # Pipeline definition
│       ├── pipelinerun.yaml           # PipelineRun manifest
│       └── workspace-template.yaml    # PVC template
├── guac/
│   ├── kind-config.yaml               # Kind cluster config
│   └── guac-deployment.yaml           # GUAC all-in-one deployment
└── scripts/
    ├── 01-bootstrap-cluster.sh        # Crea cluster + installa Tekton + GUAC
    ├── 02-setup-credentials.sh        # Genera keypair + crea secrets
    ├── 03-run-pipeline.sh             # Lancia la pipeline
    ├── 04-verify.sh                   # Verifica firma post-pipeline
    └── cleanup.sh                     # Tear down completo
```

---

## 3. Prerequisiti

### Strumenti richiesti

| Tool | Versione minima | Installazione (macOS) |
|---|---|---|
| `docker` | 24+ | `brew install --cask docker` |
| `kind` | 0.23+ | `brew install kind` |
| `kubectl` | 1.28+ | `brew install kubectl` |
| `cosign` | 2.2+ | `brew install cosign` |
| `tkn` (opzionale) | 0.37+ | `brew install tektoncd-cli` |

### Account richiesti

- **Quay.io**: Un account con push access al namespace `mronconi`
  - Crea un [Robot Account](https://quay.io/organization/mronconi?tab=robots) o usa username/password
  - Il repository `mronconi/trusted-supply-chain-app` deve esistere (crealo come public per la demo)

---

## 4. Bootstrap — Setup completo

### Step 1 — Avvia il cluster e installa le basi

```bash
# Clona il repository
git clone https://github.com/mronconi/trust-supply-chain-poc.git
cd trust-supply-chain-poc

# Bootstrap: Kind cluster + Tekton + GUAC
./scripts/01-bootstrap-cluster.sh
```

Cosa fa lo script:
1. Crea un cluster Kind a 2 nodi (`trusted-supply-chain`)
2. Installa Tekton Pipelines v0.62.0
3. Deploya GUAC (GraphQL API + Collector) nel namespace `trusted-supply-chain`
4. Applica tutte le Task e la Pipeline Tekton

**Verifica:**

```bash
# Tekton è attivo?
kubectl get pods -n tekton-pipelines
# NAME                                          READY   STATUS
# tekton-pipelines-controller-...               1/1     Running
# tekton-pipelines-webhook-...                  1/1     Running

# GUAC è attivo?
kubectl get pods -n trusted-supply-chain
# NAME                              READY   STATUS
# guac-graphql-...                  1/1     Running
# guac-collectsub-...               1/1     Running

# Pipeline è installata?
kubectl get pipelines -n trusted-supply-chain
# NAME                      AGE
# trusted-supply-chain      ...
```

---

### Step 2 — Setup credenziali e chiavi

```bash
# Genera keypair Cosign + crea i Kubernetes secrets
# Ti chiederà le credenziali Quay.io interattivamente
./scripts/02-setup-credentials.sh

# Oppure passa le credenziali via env vars:
QUAY_USERNAME=mronconi+robot QUAY_PASSWORD=xxx ./scripts/02-setup-credentials.sh
```

Cosa fa lo script:
1. **Genera un keypair Cosign** statico (senza password) in `.keys/`
2. **Crea il secret `cosign-keys`** con la coppia di chiavi
3. **Crea il secret `quay-registry-secret`** per il push su Quay.io

**Verifica:**

```bash
kubectl get secrets -n trusted-supply-chain
# NAME                    TYPE                             DATA   AGE
# cosign-keys             Opaque                           3      ...
# quay-registry-secret    kubernetes.io/dockerconfigjson   1      ...

# La chiave pubblica è in .keys/
cat .keys/cosign.pub
```

> ⚠️ **IMPORTANTE**: La directory `.keys/` è nel `.gitignore`. Non committare MAI le chiavi private.

---

## 5. Pipeline Tekton — Architettura

La pipeline `trusted-supply-chain` esegue 4 stage sequenziali:

### Stage 1: `build-and-push`

```
Git clone → Buildah build (multi-stage, UBI9) → Push su quay.io/mronconi/...
```

- Usa immagini base **Red Hat UBI9** (Universal Base Image)
- Build OCI-compliant con **Buildah** (no Docker daemon)
- Output: `IMAGE_DIGEST` per i passi successivi

### Stage 2: `generate-sbom`

```
Syft scan dell'immagine → SBOM CycloneDX 1.5 (JSON) → Cosign attest (SBOM allegato all'immagine)
```

- **Syft** genera una SBOM completa di tutte le dipendenze
- La SBOM viene **attestata** sull'immagine OCI con `cosign attest`
- Output: file SBOM per il security gate

### Stage 3: `security-gate` ⛔

```
Grype vulnerability scan → GUAC ingestion → Valutazione severità → PASS/FAIL
```

- **Grype** scansiona la SBOM contro il database delle CVE note
- La SBOM viene **ingerita in GUAC** per l'analisi del grafo delle dipendenze
- Un gate Python valuta i risultati:
  - **Se ci sono CVE CRITICAL** → ❌ il task **fallisce** con exit code 1
  - **Se non ci sono CVE CRITICAL** → ✅ il task passa

> **Questo è il punto chiave della demo**: il security gate è **bloccante**. Se fallisce,
> lo stage 4 (firma) non viene mai eseguito. L'immagine rimane non firmata sul registry.

### Stage 4: `cosign-sign`

```
Cosign sign (chiave statica) → Cosign verify (prova immediata)
```

- Firma l'immagine con la chiave privata
- Esegue subito una verifica con la chiave pubblica
- L'immagine su Quay.io ora ha una firma Cosign verificabile

---

## 6. Esecuzione della Demo

### Opzione A: Con `tkn` CLI (consigliata)

```bash
./scripts/03-run-pipeline.sh
```

Oppure direttamente:

```bash
tkn pipeline start trusted-supply-chain \
  --namespace trusted-supply-chain \
  --param IMAGE="quay.io/mronconi/trusted-supply-chain-app:latest" \
  --param GIT_URL="https://github.com/mronconi/trust-supply-chain-poc.git" \
  --param GIT_REVISION="main" \
  --param FAIL_ON_SEVERITY="critical" \
  --workspace name=shared-workspace,volumeClaimTemplateFile=tekton/pipelines/workspace-template.yaml \
  --workspace name=dockerconfig,secret=quay-registry-secret \
  --workspace name=cosign-keys,secret=cosign-keys \
  --showlog
```

### Opzione B: Con `kubectl`

```bash
kubectl create -f tekton/pipelines/pipelinerun.yaml
kubectl get pipelineruns -n trusted-supply-chain -w
```

### Seguire i log

```bash
# Con tkn
tkn pipelinerun logs -f -n trusted-supply-chain

# Con kubectl
kubectl logs -n trusted-supply-chain -l tekton.dev/pipeline=trusted-supply-chain --all-containers -f
```

---

## 7. Verifica della Firma (la "prova" per il team)

Dopo che la pipeline è completata con successo, chiunque con la chiave pubblica può verificare:

### Verifica firma dell'immagine

```bash
cosign verify \
  --key .keys/cosign.pub \
  quay.io/mronconi/trusted-supply-chain-app:latest
```

**Output atteso (successo):**

```
Verification for quay.io/mronconi/trusted-supply-chain-app:latest --
The following checks were performed on each of these signatures:
  - The cosign claims were validated
  - The signatures were verified against the specified public key

[{"critical":{"identity":{"docker-reference":"quay.io/mronconi/trusted-supply-chain-app"},
"image":{"docker-manifest-digest":"sha256:abc123..."},"type":"cosign container image signature"},
"optional":null}]
```

### Verifica attestazione SBOM

```bash
cosign verify-attestation \
  --key .keys/cosign.pub \
  --type cyclonedx \
  quay.io/mronconi/trusted-supply-chain-app:latest
```

### Script automatico

```bash
./scripts/04-verify.sh
```

---

## 8. Scenari della Demo

### ✅ Scenario 1: Gate PASSED — Pipeline completa

Quando non ci sono CVE CRITICAL nelle dipendenze:

```
▸ build-and-push    ✅ (image pushed)
▸ generate-sbom     ✅ (SBOM generated, 142 components)
▸ security-gate     ✅ PASSED — No vulnerabilities at CRITICAL+ severity
▸ cosign-sign       ✅ (image signed and verified)

╔════════════════════════════════════════╗
║  Pipeline completed successfully!      ║
║  Image is SIGNED and TRUSTED.          ║
╚════════════════════════════════════════╝
```

**Cosa mostrare al team:**
- La SBOM attaccata all'immagine OCI
- La firma verificabile con `cosign verify`
- I dati ingesti in GUAC (port-forward sulla GraphQL API)

### ❌ Scenario 2: Gate FAILED — Pipeline bloccata

Per simulare il fallimento, abbassa la soglia:

```bash
# Fallisce su HIGH+ invece che solo CRITICAL
tkn pipeline start trusted-supply-chain \
  --namespace trusted-supply-chain \
  --param IMAGE="quay.io/mronconi/trusted-supply-chain-app:latest" \
  --param FAIL_ON_SEVERITY="high" \
  --workspace name=shared-workspace,volumeClaimTemplateFile=tekton/pipelines/workspace-template.yaml \
  --workspace name=dockerconfig,secret=quay-registry-secret \
  --workspace name=cosign-keys,secret=cosign-keys \
  --showlog
```

```
▸ build-and-push    ✅ (image pushed)
▸ generate-sbom     ✅ (SBOM generated)
▸ security-gate     ❌ FAILED — 7 vulnerabilities at HIGH+ severity

  Total vulnerabilities : 23
  CRITICAL              : 0
  HIGH                  : 7
  MEDIUM                : 12
  LOW                   : 4

❌ SECURITY GATE: FAILED
   cosign-sign: SKIPPED (non eseguito)
```

**Cosa mostrare al team:**
- Lo stage `cosign-sign` non è stato eseguito
- L'immagine **non ha una firma** sul registry
- `cosign verify` **fallisce**:

```bash
cosign verify --key .keys/cosign.pub quay.io/mronconi/trusted-supply-chain-app:latest
# Error: no matching signatures
```

> **Messaggio chiave**: "Se il gate non passa, l'artefatto non viene firmato.
> Nessuno può deployare un'immagine non firmata se la policy lo richiede."

---

## 9. Esplorare GUAC

Per ispezionare il grafo delle dipendenze in GUAC:

```bash
# Port-forward al GraphQL endpoint
kubectl port-forward svc/guac-graphql 8080:8080 -n trusted-supply-chain

# Apri il playground GraphQL
open http://localhost:8080

# Query di esempio: trova tutti i package noti
curl -s http://localhost:8080/query \
  -H "Content-Type: application/json" \
  -d '{"query":"{ packages(pkgSpec: {}) { type namespaces { namespace names { name versions { version } } } } }"}' | python3 -m json.tool
```

---

## 10. Mapping con i prodotti Red Hat

| Cosa abbiamo usato nella PoC | Equivalente in produzione (Red Hat) |
|---|---|
| Kind cluster | OpenShift (ROSA, ARO, self-managed) |
| Tekton Pipelines vanilla | **Red Hat OpenShift Pipelines** (operatore certificato) |
| Cosign con chiavi statiche | **Red Hat Trusted Artifact Signer (TAS)** con Sigstore Fulcio + Rekor per keyless signing |
| GUAC standalone | **Red Hat Trusted Profile Analyzer (TPA)** con UI, policy engine, e integrazione con Red Hat CVE data |
| Grype | Red Hat ACS (Advanced Cluster Security) / TPA vulnerability analysis |
| Quay.io (SaaS) | **Red Hat Quay** (on-premise o cloud) con mirror e proxy cache |
| CycloneDX SBOM manuale | Generazione SBOM integrata nel build system di Trusted Application Pipeline |

**In produzione con Red Hat**, il flusso diventa:
- **Keyless signing** tramite OIDC (niente chiavi statiche da gestire)
- **Transparency log** (Rekor) per audit immutabile di ogni firma
- **Policy engine** per definire regole di ammissione granulari
- **Enterprise CVE feed** con dati specifici Red Hat

---

## 11. Cleanup

```bash
./scripts/cleanup.sh
```

Rimuove il cluster Kind e la directory `.keys/`.

---

## 12. Riferimenti

- [Sigstore — Software signing for everyone](https://www.sigstore.dev/)
- [GUAC — Graph for Understanding Artifact Composition](https://guac.sh/)
- [Tekton — Cloud-Native CI/CD](https://tekton.dev/)
- [CycloneDX — SBOM Standard](https://cyclonedx.org/)
- [Red Hat Trusted Software Supply Chain](https://www.redhat.com/en/solutions/trusted-software-supply-chain)
- [Red Hat Trusted Application Pipeline](https://docs.redhat.com/en/documentation/red_hat_trusted_application_pipeline/)
- [Red Hat Trusted Artifact Signer](https://docs.redhat.com/en/documentation/red_hat_trusted_artifact_signer/)
- [Red Hat Trusted Profile Analyzer](https://docs.redhat.com/en/documentation/red_hat_trusted_profile_analyzer/)
- [Quarkus — Supersonic Subatomic Java](https://quarkus.io/)

---

> **Nota**: Questa PoC usa chiavi statiche per semplicità. In un ambiente di produzione,
> si utilizzerebbe il keyless signing di Sigstore (Fulcio + Rekor) integrato in TAS,
> eliminando completamente la gestione delle chiavi private.
