# Architecture — Security-First CI/CD Pipeline on AWS EKS

## Overview

This project implements a production-grade, security-first CI/CD pipeline for the [Online Boutique](https://github.com/GoogleCloudPlatform/microservices-demo) polyglot microservices application, deployed to AWS EKS via GitOps (ArgoCD).

**Portfolio focus**: DevSecOps, supply-chain security, least-privilege IAM, GitOps, and observability.

---

## System Architecture

```
┌────────────────────────────────────────────────────────────────────────────┐
│                        GitHub (Source of Truth)                            │
│                                                                            │
│  Pruthviraj-333/security-cicd-eks-pipeline                                 │
│  ├── microservices-demo/kubernetes-manifests/   ← ArgoCD watches this      │
│  ├── terraform/                                 ← EKS infra definitions    │
│  └── .github/workflows/                         ← 8-stage pipeline        │
└────────────────────────┬───────────────────────────────────────────────────┘
                         │ push / PR
                         ▼
┌────────────────────────────────────────────────────────────────────────────┐
│                   GitHub Actions (CI/CD Runtime)                           │
│                                                                            │
│  ┌──────────────────────────────────────────────────────────────────────┐  │
│  │  PRE-MERGE GATES (Stages 1–4) — run on every PR                     │  │
│  │                                                                      │  │
│  │  Stage 1: Secrets Scan    ┐                                          │  │
│  │  Stage 2: SAST            ├─ PARALLEL → GitHub Security tab (SARIF) │  │
│  │  Stage 3: SCA             │                                          │  │
│  │  Stage 4: IaC Scan        ┘                                          │  │
│  └──────────────────────────────────────────────────────────────────────┘  │
│                         │ merge to main                                    │
│  ┌──────────────────────▼───────────────────────────────────────────────┐  │
│  │  POST-MERGE PIPELINE (Stages 5–8) — runs on main branch only        │  │
│  │                                                                      │  │
│  │  Stage 5: Build → Sign → Verify                                     │  │
│  │           │                                                          │  │
│  │           ▼ triggers                                                 │  │
│  │  Stage 6: Update manifests → ArgoCD sync                            │  │
│  │           │                                                          │  │
│  │  Stage 7: Drift Detection (every 30 min, scheduled)                 │  │
│  │  Stage 8: Dashboard aggregation (after any stage, + daily)          │  │
│  └──────────────────────────────────────────────────────────────────────┘  │
└────────────────────────┬───────────────────────────────────────────────────┘
                         │ OIDC (no stored keys)
                         ▼
┌────────────────────────────────────────────────────────────────────────────┐
│                          AWS Account                                       │
│                                                                            │
│  ┌─────────────────────────────┐   ┌──────────────────────────────────┐   │
│  │  VPC (10.0.0.0/16)          │   │  Security Services               │   │
│  │  ├── Public subnets  (NAT)  │   │  ├── KMS (secrets + EBS)         │   │
│  │  └── Private subnets (EKS)  │   │  ├── CloudWatch (logs + metrics) │   │
│  └──────────────┬──────────────┘   │  └── IAM OIDC Provider           │   │
│                 │                  └──────────────────────────────────┘   │
│  ┌──────────────▼──────────────────────────────────────────────────────┐   │
│  │  EKS Cluster (K8s 1.32)                                             │   │
│  │                                                                     │   │
│  │  kube-system/                                                       │   │
│  │  ├── aws-load-balancer-controller  (IRSA)                          │   │
│  │  ├── cluster-autoscaler            (IRSA)                          │   │
│  │  └── aws-ebs-csi-driver            (IRSA)                          │   │
│  │                                                                     │   │
│  │  argocd/                           (IRSA — ECR read + EKS describe) │   │
│  │  ├── argocd-server                                                  │   │
│  │  ├── argocd-application-controller ← watches git, syncs manifests  │   │
│  │  └── argocd-repo-server                                             │   │
│  │                                                                     │   │
│  │  monitoring/                       (IRSA — CloudWatch read)         │   │
│  │  ├── prometheus                    ← scrapes cluster + ArgoCD       │   │
│  │  ├── grafana                       ← dashboards (CW + Loki + Prom) │   │
│  │  ├── loki                          ← log aggregation                │   │
│  │  └── promtail                      ← ships pod logs → Loki          │   │
│  │                                                                     │   │
│  │  default/                                                           │   │
│  │  ├── frontend          (Go 1.27, distroless, IRSA SA)              │   │
│  │  ├── cartservice       (C# .NET 10, chiseled, IRSA SA)             │   │
│  │  └── checkoutservice   (Go 1.27, distroless, IRSA SA)              │   │
│  └─────────────────────────────────────────────────────────────────────┘   │
│                                                                            │
│  GHCR (ghcr.io/pruthviraj-333/)                                            │
│  ├── frontend:sha-<commit>        ← Cosign signed + SBOM attached          │
│  ├── cartservice:sha-<commit>     ← Cosign signed + SBOM attached          │
│  └── checkoutservice:sha-<commit> ← Cosign signed + SBOM attached          │
└────────────────────────────────────────────────────────────────────────────┘
```

---

## Security Controls by Layer

### CI/CD Layer

| Control | Implementation |
|---------|----------------|
| Pre-commit secret scanning | Gitleaks (SARIF) + TruffleHog (verified) |
| Static analysis (SAST) | gosec (Go) + Semgrep (Go + C# custom rules) |
| Dependency scanning (SCA) | govulncheck + `dotnet list --vulnerable` + Trivy |
| IaC scanning | Checkov (Terraform + K8s + Helm) + kube-linter + tfsec |
| Supply-chain signing | Cosign keyless OIDC — no stored private keys |
| SBOM generation | Syft → SPDX JSON attached as OCI attestation |
| SLSA provenance | Docker Buildx L2 provenance + Cosign attestation |
| Zero stored AWS keys | GitHub Actions OIDC → scoped IAM role (repo+branch) |

### Infrastructure Layer

| Control | Implementation |
|---------|----------------|
| Secrets encryption | KMS CMK for Kubernetes secrets (CKV_AWS_58) |
| EBS encryption | KMS CMK on all node root volumes (CKV_AWS_337) |
| Node isolation | Worker nodes in private subnets only |
| IMDSv2 enforcement | `http_tokens = required`, hop limit = 1 |
| Control plane logging | All 5 log types → CloudWatch (CKV_AWS_37) |
| VPC flow logs | All traffic logged → CloudWatch (CKV2_AWS_11) |
| API endpoint | Private + public (CIDR-restricted) (CKV_AWS_38/39) |
| Key rotation | KMS auto-rotation enabled (CKV_AWS_7) |

### Workload Layer

| Control | Implementation |
|---------|----------------|
| Least-privilege IAM | Separate IRSA role per component (no node-level IAM) |
| Pod Security | `runAsNonRoot`, `readOnlyRootFilesystem`, `allowPrivilegeEscalation: false` |
| Capability dropping | `capabilities.drop: [ALL]` on all containers |
| Network isolation | VPC-CNI network policy enabled |
| Image verification | Cosign verify before deploy (Stage 6) |
| Continuous reconciliation | ArgoCD self-heal + drift detection every 30 min |

---

## IRSA Role Map

```
Component                    IAM Role                          Permissions
─────────────────────────────────────────────────────────────────────────────
argocd-application-controller security-cicd-dev-argocd-controller  ECR read + EKS describe
argocd-server                 security-cicd-dev-argocd-server       EKS describe
grafana                       security-cicd-dev-grafana             CloudWatch read
aws-ebs-csi-driver            security-cicd-dev-ebs-csi             EC2 EBS + KMS
cluster-autoscaler            security-cicd-dev-cluster-autoscaler  ASG (tag-scoped)
aws-load-balancer-controller  security-cicd-dev-alb-controller      ELB + EC2
github-actions (CI)           security-cicd-dev-github-actions-deploy EKS + ECR (repo-scoped)
```

---

## Pilot Services

| Service | Language | Base Image | Port |
|---------|----------|------------|------|
| `frontend` | Go 1.27 | `gcr.io/distroless/static` | 8080 |
| `cartservice` | C# .NET 10 | `mcr.microsoft.com/dotnet/runtime-deps:chiseled` | 7070 |
| `checkoutservice` | Go 1.27 | `gcr.io/distroless/static` | 5050 |

All three use:
- Pinned SHA digest base images in Dockerfiles
- Distroless/chiseled (no shell, no package manager)
- GHCR as image registry with Cosign keyless signing

---

## Getting Started

### Prerequisites

```bash
# Tools required locally
terraform >= 1.5   # brew install terraform
aws-cli >= 2.x     # brew install awscli
kubectl            # brew install kubectl
argocd-cli         # brew install argocd
cosign             # brew install cosign
gh                 # brew install gh
```

### 1. Clone and configure

```bash
git clone https://github.com/Pruthviraj-333/security-cicd-eks-pipeline.git
cd security-cicd-eks-pipeline

cp terraform/terraform.tfvars.example terraform/terraform.tfvars
# Edit terraform.tfvars — set aws_account_id and aws_region
```

### 2. Provision infrastructure

```bash
cd terraform/
terraform init
terraform plan -out=tfplan
terraform apply tfplan

# Configure kubectl
aws eks update-kubeconfig --name security-cicd-dev-security-cicd-eks --region ap-south-1
```

### 3. Add GitHub Secrets

| Secret | Value |
|--------|-------|
| `AWS_ACCOUNT_ID` | Your 12-digit AWS account ID |
| `GITLEAKS_LICENSE` | Optional — only for SARIF on private repos |

### 4. Trigger the pipeline

```bash
# Make any change to a pilot service and push
git checkout -b feat/test-pipeline
echo "# test" >> microservices-demo/src/frontend/README.md
git commit -am "test: trigger pipeline"
git push origin feat/test-pipeline
gh pr create --fill
```

### 5. Access Grafana

```bash
kubectl port-forward svc/kube-prometheus-stack-grafana -n monitoring 3000:80
# Open: http://localhost:3000
# User: admin
# Pass: kubectl -n monitoring get secret kube-prometheus-stack-grafana \
#         -o jsonpath='{.data.admin-password}' | base64 -d
```

### 6. Verify image signatures

```bash
cosign verify \
  --certificate-oidc-issuer https://token.actions.githubusercontent.com \
  --certificate-identity-regexp "^https://github.com/Pruthviraj-333/security-cicd-eks-pipeline/.github/workflows/stage5-image-sign.yml" \
  ghcr.io/pruthviraj-333/frontend:latest
```
