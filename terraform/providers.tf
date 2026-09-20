# terraform/providers.tf
# ─────────────────────────────────────────────────────────────────────────────
# Provider configuration — AWS, Kubernetes, Helm
# Kubernetes and Helm providers are configured after cluster creation using
# data sources (not hardcoded endpoints) to avoid chicken-and-egg issues.
# ─────────────────────────────────────────────────────────────────────────────

provider "aws" {
  region = var.aws_region

  # All resources get these default tags automatically
  default_tags {
    tags = merge(
      {
        Project     = var.project_name
        Environment = var.environment
        Owner       = var.owner
        ManagedBy   = "terraform"
        Repository  = "github.com/Pruthviraj-333/security-cicd-eks-pipeline"
      },
      var.additional_tags
    )
  }
}

# ── Kubernetes provider (configured after cluster creation) ──────────────────
# Uses the cluster token + CA from the EKS data source — no kubeconfig file needed.
provider "kubernetes" {
  host                   = module.eks.cluster_endpoint
  cluster_ca_certificate = base64decode(module.eks.cluster_certificate_authority_data)

  exec {
    api_version = "client.authentication.k8s.io/v1beta1"
    command     = "aws"
    args = [
      "eks", "get-token",
      "--cluster-name", module.eks.cluster_name,
      "--region", var.aws_region
    ]
  }
}

# ── Helm provider (for ArgoCD + monitoring installs) ─────────────────────────
provider "helm" {
  kubernetes {
    host                   = module.eks.cluster_endpoint
    cluster_ca_certificate = base64decode(module.eks.cluster_certificate_authority_data)

    exec {
      api_version = "client.authentication.k8s.io/v1beta1"
      command     = "aws"
      args = [
        "eks", "get-token",
        "--cluster-name", module.eks.cluster_name,
        "--region", var.aws_region
      ]
    }
  }
}
