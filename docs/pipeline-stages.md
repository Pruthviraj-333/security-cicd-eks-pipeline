# Pipeline Stages Reference

Detailed breakdown of all 8 security stages, their tools, triggers, failure policies, and outputs.

---

## Stage 1 — Pre-Commit Secrets Scanning

**Workflow**: [`.github/workflows/stage1-secrets-scan.yml`](../.github/workflows/stage1-secrets-scan.yml)  
**Trigger**: Every push + PR to `main` (path-filtered to pilot services)

### Tools

| Tool | Mode | Output |
|------|------|--------|
| [Gitleaks v2](https://github.com/gitleaks/gitleaks) | Git diff + full history | SARIF → GitHub Security tab |
| [TruffleHog](https://github.com/trufflesecurity/trufflehog) | Verified secrets only | JSON artifact |

### Configuration files
- [`.gitleaks.toml`](../.gitleaks.toml) — custom rules (AWS keys, GH PATs, PEM blocks, K8s secrets)
- [`.trufflehog-exclude.txt`](../.trufflehog-exclude.txt) — safe path exclusions

### Failure policy

| Severity | Action |
|----------|--------|
| CRITICAL / HIGH (Gitleaks) | Block merge |
| Verified (TruffleHog) | Block merge |
| MEDIUM / LOW | Warn, allow merge |

### Jobs
```
gitleaks-scan ──────┐
                    ├──► secrets-report → PR comment + merge gate
trufflehog-scan ────┘
```

---

## Stage 2 — Static Application Security Testing (SAST)

**Workflow**: [`.github/workflows/stage2-sast.yml`](../.github/workflows/stage2-sast.yml)  
**Trigger**: Every push + PR (path-filtered to pilot services)

### Tools

| Tool | Languages | Rules |
|------|-----------|-------|
| [gosec](https://github.com/securego/gosec) | Go | Standard + medium/high severity |
| [Semgrep](https://semgrep.dev/) | Go + C# | `p/golang` + `p/csharp` + `p/owasp-top-ten` + custom |

### Custom Semgrep rules ([`.semgrep/custom-rules.yml`](../.semgrep/custom-rules.yml))

| Rule ID | What it catches | Severity |
|---------|-----------------|----------|
| `go-tls-insecure-skip-verify` | TLS verification disabled | ERROR |
| `go-grpc-no-tls` | `grpc.WithInsecure()` usage | WARNING |
| `go-log-sensitive-field` | Password/token in log fields | WARNING |
| `csharp-connection-string-hardcoded` | Inline DB connection strings | ERROR |
| `csharp-tls-no-validation` | `ServerCertificateValidationCallback = true` | ERROR |
| `csharp-redis-no-tls` | Redis without SSL | WARNING |

### Failure policy

| Finding | Action |
|---------|--------|
| gosec HIGH/CRITICAL | Block merge |
| Semgrep ERROR-level | Block merge |
| WARNING / MEDIUM | Warn, allow merge |

---

## Stage 3 — Software Composition Analysis (SCA)

**Workflow**: [`.github/workflows/stage3-sca.yml`](../.github/workflows/stage3-sca.yml)  
**Trigger**: Push + PR + **weekly Monday 03:00 UTC** (catches new CVEs)

### Tools

| Tool | Scope | Database |
|------|-------|----------|
| [govulncheck](https://pkg.go.dev/golang.org/x/vuln/cmd/govulncheck) | Go modules | Go Vuln DB (pkg.go.dev/vuln) |
| [`dotnet list --vulnerable`](https://learn.microsoft.com/en-us/dotnet/core/tools/dotnet-list-package) | NuGet (.NET 10) | NuGet Advisory DB |
| [Trivy](https://github.com/aquasecurity/trivy) | All services (fs scan) | OSV + NVD + GitHub Advisories |

> **govulncheck advantage**: Unlike Trivy/Snyk, govulncheck only reports vulnerabilities in code paths that are actually *called*, not just imported. This eliminates most false positives.

### Failure policy

| Severity | Action |
|----------|--------|
| CRITICAL (any tool) | Block merge |
| HIGH (any tool) | Block merge |
| MEDIUM | Warn |
| Unfixable (no upstream patch) | Info only (Trivy `--ignore-unfixed`) |

---

## Stage 4 — Infrastructure-as-Code (IaC) Scanning

**Workflow**: [`.github/workflows/stage4-iac-scan.yml`](../.github/workflows/stage4-iac-scan.yml)  
**Trigger**: Push + PR (path-filtered to `terraform/` and `kubernetes-manifests/`)

### Tools

| Tool | Scope | Key checks |
|------|-------|------------|
| [Checkov](https://www.checkov.io/) | Terraform + K8s + Helm | EKS encryption, logging, endpoint access |
| [kube-linter](https://docs.kubelinter.io/) | K8s manifests (pilot services) | Security context, RBAC, probes, resources |
| [tfsec](https://aquasecurity.github.io/tfsec/) | Terraform (AWS) | EKS, VPC, KMS, IAM rules |

### Key checks enforced

**Kubernetes (Checkov + kube-linter)**

| Check | Description |
|-------|-------------|
| `CKV_K8S_30` | `seccompProfile` must be configured |
| `CKV_K8S_36` | `readOnlyRootFilesystem: true` |
| `CKV2_K8S_6` | NetworkPolicy required per namespace |
| `run-as-non-root` | `runAsNonRoot: true` enforced |
| `privilege-escalation-container` | `allowPrivilegeEscalation: false` |
| `memory-limit` | Resource limits must be set |

**Terraform/AWS (Checkov + tfsec)**

| Check | Description |
|-------|-------------|
| `CKV_AWS_58` | EKS secrets encryption (KMS) |
| `CKV_AWS_37` | All 5 control plane log types enabled |
| `CKV_AWS_38/39` | API endpoint: public CIDR-restricted + private enabled |
| `CKV_AWS_337` | Node EBS encrypted with KMS |
| `CKV_AWS_7` | KMS key auto-rotation enabled |

---

## Stage 5 — Container Image Build + Supply-Chain Signing

**Workflow**: [`.github/workflows/stage5-image-sign.yml`](../.github/workflows/stage5-image-sign.yml)  
**Trigger**: Push to `main` only (not PRs)

### Flow

```
Docker Buildx (linux/amd64)
    │
    ├── Push to GHCR (ghcr.io/pruthviraj-333/<service>)
    │   Tags: :latest, :sha-<short>, :main-YYYYMMDD
    │
    ├── Cosign sign (keyless OIDC)
    │   Identity: GitHub Actions OIDC token
    │   CA: Sigstore Fulcio
    │   Log: Sigstore Rekor (public, append-only)
    │
    ├── Syft SBOM (SPDX JSON → OCI attestation)
    │
    ├── SLSA L2 provenance attestation
    │
    └── Cosign verify (round-trip check — fails job if invalid)
```

### Verification

```bash
# Anyone can verify without access to CI:
cosign verify \
  --certificate-oidc-issuer https://token.actions.githubusercontent.com \
  --certificate-identity-regexp "^https://github.com/Pruthviraj-333/security-cicd-eks-pipeline/.github/workflows/stage5-image-sign.yml" \
  ghcr.io/pruthviraj-333/frontend:latest
```

### Why keyless?

No private keys stored anywhere — the signing identity is the GitHub Actions OIDC token. The public Rekor log provides tamper-evident proof of when and by which workflow the image was signed.

---

## Stage 6 — GitOps Deploy (ArgoCD)

**Workflow**: [`.github/workflows/stage6-gitops-deploy.yml`](../.github/workflows/stage6-gitops-deploy.yml)  
**Trigger**: After Stage 5 succeeds on main

### Flow

```
1. Verify all 3 service image signatures (cosign verify)
2. Resolve latest image digest from GHCR (:latest → @sha256:...)
3. Update image references in kubernetes-manifests/*.yaml
4. Commit + push (GitOps pattern — git is the source of truth)
5. Trigger ArgoCD app sync
6. Poll ArgoCD for Synced + Healthy (5 min timeout)
7. Auto-rollback if Degraded health detected
```

### ArgoCD configuration

| Setting | Value |
|---------|-------|
| Source repo | `Pruthviraj-333/security-cicd-eks-pipeline` |
| Source path | `microservices-demo/kubernetes-manifests/` |
| Target cluster | `https://kubernetes.default.svc` |
| Namespace | `default` |
| Automated sync | `prune: true`, `selfHeal: true` |
| RBAC default | `role:readonly` |

---

## Stage 7 — Drift Detection

**Workflow**: [`.github/workflows/stage7-drift-detection.yml`](../.github/workflows/stage7-drift-detection.yml)  
**Trigger**: Every 30 minutes (scheduled) + manual dispatch

### Detection methods

| Method | What it catches |
|--------|-----------------|
| `argocd app diff` | Any resource out-of-sync with git |
| `kubectl` vs git manifest diff | Field-level config drift (after stripping runtime fields) |
| Image digest check | Running image doesn't match pinned digest in git |

### Alerting

| Trigger | Action |
|---------|--------|
| Drift detected | GitHub Issue created/updated with diff |
| Drift resolved | Issue auto-closed |
| CloudWatch metric | `SecurityCICD/DriftDetection/DriftDetected` = 1 |
| CloudWatch alarm | Fires after 1 evaluation period (5 min) |

---

## Stage 8 — Security Dashboard

**Workflow**: [`.github/workflows/stage8-dashboard.yml`](../.github/workflows/stage8-dashboard.yml)  
**Trigger**: After any stage completes + daily 06:00 UTC

### Outputs

| Destination | Contents |
|-------------|----------|
| CloudWatch (`SecurityCICD/PipelineMetrics`) | Per-stage pass rates, pipeline runs |
| Grafana (via CloudWatch datasource) | Security Pipeline Overview dashboard |
| Grafana (via Loki datasource) | Scan finding logs |
| GitHub Actions Job Summary | Always-on ASCII dashboard (zero infra needed) |

### Grafana dashboards

| Dashboard | UID | Data sources |
|-----------|-----|--------------|
| Security Pipeline Overview | `security-pipeline-v1` | CloudWatch + Loki |
| GitOps & Drift Detection | `gitops-drift-v1` | CloudWatch |

---

## Expanding to All 11 Services

Once the 3 pilot services are fully validated end-to-end:

1. **Add services to workflow path filters** (Stages 1–4)
2. **Add matrix entries** to the build/sign job (Stage 5)
3. **Add manifest update entries** in the deploy job (Stage 6)
4. **Update ArgoCD Application** source path to include all service manifests
5. **Add kube-linter / Checkov targets** for new service manifests

Services to expand to: `adservice`, `currencyservice`, `emailservice`, `paymentservice`, `productcatalogservice`, `recommendationservice`, `shippingservice`, `shoppingassistantservice`
