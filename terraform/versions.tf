# terraform/versions.tf
# ─────────────────────────────────────────────────────────────────────────────
# Terraform and provider version constraints
# Pinned to exact versions for reproducible infrastructure builds
# ─────────────────────────────────────────────────────────────────────────────

terraform {
  required_version = ">= 1.5.0, < 2.0.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.82"
    }
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "~> 2.35"
    }
    helm = {
      source  = "hashicorp/helm"
      version = "~> 2.17"
    }
    tls = {
      source  = "hashicorp/tls"
      version = "~> 4.0"
    }
    time = {
      source  = "hashicorp/time"
      version = "~> 0.12"
    }
  }

  # ── Remote state (S3 + DynamoDB) ─────────────────────────────────────────
  # Uncomment and fill in before running terraform init in production.
  # The backend bucket + table must exist before first init.
  # Create them manually or with the bootstrap script in docs/terraform-bootstrap.md
  #
  # backend "s3" {
  #   bucket         = "your-tfstate-bucket-name"
  #   key            = "security-cicd-eks-pipeline/terraform.tfstate"
  #   region         = "ap-south-1"
  #   encrypt        = true
  #   dynamodb_table = "terraform-state-lock"
  #   kms_key_id     = "arn:aws:kms:ap-south-1:ACCOUNT_ID:key/KEY_ID"
  # }
}
