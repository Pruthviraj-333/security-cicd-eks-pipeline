# Security-First CI/CD Pipeline on AWS EKS

> **Portfolio project** — DevSecOps · Supply-chain security · GitOps · AWS EKS

A production-grade, 8-stage security pipeline for the [Online Boutique](https://github.com/GoogleCloudPlatform/microservices-demo) polyglot microservices app (Go · C# · Python · Java · Node.js), deployed to AWS EKS via ArgoCD.

---

## Pipeline Overview

```
 PR / Push
    │
    ├─ [1] Secrets Scan     Gitleaks + TruffleHog (parallel, SARIF)
    ├─ [2] SAST             gosec (Go matrix) + Semgrep (Go+C#, custom rules)
    ├─ [3] SCA              govulncheck + dotnet vuln + Trivy
    └─ [4] IaC Scan         Checkov + kube-linter + tfsec
                    │
              merge to main
                    │
    ├─ [5] Build + Sign     Docker Buildx → GHCR → Cosign keyless + SBOM
    ├─ [6] GitOps Deploy    Manifest update → ArgoCD sync + health gate
    ├─ [7] Drift Detection  argocd diff + kubectl (every 30 min, CloudWatch)
    └─ [8] Dashboard        CloudWatch metrics + Grafana + GitHub Summary
```

**Pilot services**: `frontend` (Go) · `cartservice` (C# .NET 10) · `checkoutservice` (Go)

---

## Key Security Properties

| Property | Implementation |
|----------|----------------|
| No stored AWS keys | GitHub Actions OIDC → scoped IAM role (repo+branch) |
| No signing private keys | Cosign keyless (Sigstore Fulcio + Rekor transparency log) |
| SBOM on every image | Syft → SPDX JSON attached as OCI attestation |
| Least-privilege IAM | Separate IRSA role per workload (not node-level) |
| Continuous reconciliation | ArgoCD self-heal + drift detection every 30 min |
| Encrypted at rest | KMS for EKS secrets + EBS volumes + CloudWatch logs |
| Network isolation | Worker nodes in private subnets — no public IPs |
| IaC compliance | All Terraform passes Checkov CKV_AWS_37/38/39/58/337 |

---

## Repository Structure

```
security-cicd-eks-pipeline/
├── .github/workflows/
│   ├── stage1-secrets-scan.yml       # Gitleaks + TruffleHog
│   ├── stage2-sast.yml               # gosec + Semgrep
│   ├── stage3-sca.yml                # govulncheck + Trivy + dotnet
│   ├── stage4-iac-scan.yml           # Checkov + kube-linter + tfsec
│   ├── stage5-image-sign.yml         # Docker Build + Cosign + SBOM + SLSA
│   ├── stage6-gitops-deploy.yml      # Manifest update + ArgoCD sync
│   ├── stage7-drift-detection.yml    # Scheduled drift check + GitHub Issues
│   └── stage8-dashboard.yml          # CloudWatch + Grafana aggregation
│
├── terraform/
│   ├── versions.tf                   # Provider pins
│   ├── providers.tf                  # AWS + K8s + Helm (exec auth)
│   ├── variables.tf                  # All inputs with validation
│   ├── locals.tf                     # Name prefix, OIDC, SA names
│   ├── vpc.tf                        # VPC + subnets + flow logs + endpoints
│   ├── kms.tf                        # KMS CMK (auto-rotate, scoped policy)
│   ├── eks.tf                        # EKS cluster + node group + add-ons
│   ├── irsa.tf                       # 6 IRSA roles (least-privilege)
│   ├── argocd.tf                     # ArgoCD Helm + Application CR
│   ├── monitoring.tf                 # Prometheus + Grafana + Loki + dashboards
│   ├── github-actions-oidc.tf        # GitHub OIDC provider + deploy role
│   ├── outputs.tf                    # Cluster, IRSA ARNs, convenience commands
│   └── terraform.tfvars.example      # Template — copy to terraform.tfvars
│
├── microservices-demo/               # Forked from GoogleCloudPlatform/microservices-demo
│   ├── src/                          # Service source code
│   └── kubernetes-manifests/         # K8s manifests (ArgoCD source of truth)
│
├── docs/
│   ├── architecture.md               # System architecture + diagrams
│   └── pipeline-stages.md            # Stage-by-stage reference
│
├── .semgrep/custom-rules.yml         # Custom SAST rules (TLS, gRPC, log leak)
├── .checkov.yaml                     # Checkov check list + skip list
├── .kube-linter.yaml                 # kube-linter security checks
├── .gitleaks.toml                    # Gitleaks rules + allowlists
├── .trufflehog-exclude.txt           # TruffleHog safe path exclusions
└── cosign.policy.yaml                # Cosign ClusterImagePolicy (for Kyverno)
```

---

## Quick Start

### 1. Provision the EKS cluster

```bash
cd terraform/
cp terraform.tfvars.example terraform.tfvars
# Edit: set aws_account_id + aws_region

terraform init
terraform plan -out=tfplan
terraform apply tfplan

# Configure kubectl
aws eks update-kubeconfig --name security-cicd-dev-security-cicd-eks --region ap-south-1
```

### 2. Add GitHub Secrets

| Secret | Value |
|--------|-------|
| `AWS_ACCOUNT_ID` | Your 12-digit AWS account ID |

### 3. Trigger the full pipeline

```bash
git checkout -b feat/trigger-pipeline
echo "# test" >> microservices-demo/src/frontend/README.md
git commit -am "test: trigger full pipeline"
git push origin feat/trigger-pipeline
gh pr create --fill   # Stages 1-4 run on PR
gh pr merge --squash  # Stages 5-8 run on merge to main
```

### 4. View Grafana

```bash
kubectl port-forward svc/kube-prometheus-stack-grafana -n monitoring 3000:80
# http://localhost:3000 | admin / $(kubectl -n monitoring get secret kube-prometheus-stack-grafana -o jsonpath='{.data.admin-password}' | base64 -d)
```

### 5. Verify image signature (anyone, anywhere)

```bash
cosign verify \
  --certificate-oidc-issuer https://token.actions.githubusercontent.com \
  --certificate-identity-regexp "^https://github.com/Pruthviraj-333/security-cicd-eks-pipeline/.github/workflows/stage5-image-sign.yml" \
  ghcr.io/pruthviraj-333/frontend:latest
```

---

## Documentation

- [Architecture](docs/architecture.md) — full system diagram + security controls by layer
- [Pipeline Stages](docs/pipeline-stages.md) — tools, failure policies, configs per stage

---

## Tech Stack

| Category | Tools |
|----------|-------|
| CI/CD runtime | GitHub Actions |
| Secret scanning | Gitleaks v2, TruffleHog |
| SAST | gosec, Semgrep |
| SCA | govulncheck, Trivy, dotnet CLI |
| IaC scanning | Checkov, kube-linter, tfsec |
| Image registry | GitHub Container Registry (GHCR) |
| Image signing | Cosign (keyless), Sigstore Fulcio, Sigstore Rekor |
| SBOM | Syft (SPDX JSON) |
| Infrastructure | Terraform (AWS provider v5) |
| Compute | AWS EKS 1.32, Managed Node Groups (AL2023) |
| Networking | AWS VPC, NAT Gateway, VPC Endpoints, VPC-CNI |
| Security | AWS KMS, IAM IRSA, OIDC federation |
| GitOps | ArgoCD |
| Monitoring | Prometheus, Grafana, Loki, Promtail |
| Observability | CloudWatch (metrics + logs + alarms) |

---

*Built as a DevSecOps portfolio project demonstrating end-to-end security automation from code commit to production deployment.*
