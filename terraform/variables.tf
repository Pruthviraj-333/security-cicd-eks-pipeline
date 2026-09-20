# terraform/variables.tf
# ─────────────────────────────────────────────────────────────────────────────
# All input variables for the EKS security-cicd-eks-pipeline infrastructure.
# Defaults are production-safe; override in terraform.tfvars (not committed).
# ─────────────────────────────────────────────────────────────────────────────

# ── Project metadata ─────────────────────────────────────────────────────────

variable "project_name" {
  description = "Prefix applied to all resource names for identification"
  type        = string
  default     = "security-cicd"

  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{1,20}$", var.project_name))
    error_message = "project_name must be lowercase alphanumeric with hyphens, 2-21 chars."
  }
}

variable "environment" {
  description = "Deployment environment (dev | staging | prod)"
  type        = string
  default     = "dev"

  validation {
    condition     = contains(["dev", "staging", "prod"], var.environment)
    error_message = "environment must be one of: dev, staging, prod."
  }
}

variable "owner" {
  description = "Owner tag applied to all resources (GitHub username or team)"
  type        = string
  default     = "Pruthviraj-333"
}

# ── AWS ───────────────────────────────────────────────────────────────────────

variable "aws_region" {
  description = "AWS region to deploy all resources into"
  type        = string
  default     = "ap-south-1"   # Mumbai — change to your preferred region
}

variable "aws_account_id" {
  description = "AWS Account ID — used for KMS key policy and IRSA ARN construction"
  type        = string
  # No default — must be set in tfvars or via TF_VAR_aws_account_id env var
}

# ── VPC / Networking ──────────────────────────────────────────────────────────

variable "vpc_cidr" {
  description = "CIDR block for the VPC"
  type        = string
  default     = "10.0.0.0/16"

  validation {
    condition     = can(cidrhost(var.vpc_cidr, 0))
    error_message = "vpc_cidr must be a valid IPv4 CIDR block."
  }
}

variable "availability_zones" {
  description = "List of AZs to use (must be >= 2 for EKS HA). Defaults to first 3 AZs in region."
  type        = list(string)
  default     = ["ap-south-1a", "ap-south-1b", "ap-south-1c"]
}

variable "public_subnet_cidrs" {
  description = "CIDR blocks for public subnets (one per AZ — for ALB, NAT GW)"
  type        = list(string)
  default     = ["10.0.1.0/24", "10.0.2.0/24", "10.0.3.0/24"]
}

variable "private_subnet_cidrs" {
  description = "CIDR blocks for private subnets (one per AZ — for EKS nodes)"
  type        = list(string)
  default     = ["10.0.11.0/24", "10.0.12.0/24", "10.0.13.0/24"]
}

variable "enable_nat_gateway" {
  description = "Create NAT gateways for private subnet egress (required for EKS nodes)"
  type        = bool
  default     = true
}

variable "single_nat_gateway" {
  description = "Use a single NAT gateway (cost savings for dev; set false for prod HA)"
  type        = bool
  default     = true   # Override to false for staging/prod
}

# ── EKS Cluster ───────────────────────────────────────────────────────────────

variable "cluster_name" {
  description = "Name of the EKS cluster"
  type        = string
  default     = "security-cicd-eks"
}

variable "cluster_version" {
  description = "Kubernetes version for EKS cluster (check AWS EKS supported versions)"
  type        = string
  default     = "1.32"
}

variable "cluster_endpoint_public_access" {
  description = "Allow public access to EKS API endpoint"
  type        = bool
  default     = true   # Required for GitHub Actions runners; lock down via CIDR below
}

variable "cluster_endpoint_public_access_cidrs" {
  description = "CIDR blocks allowed to access the public EKS API endpoint"
  type        = list(string)
  # Default: GitHub Actions IP ranges + common cloud providers
  # In production, restrict to your office/VPN CIDR or use private endpoint only
  default     = ["0.0.0.0/0"]   # Override in tfvars for production!
}

variable "cluster_endpoint_private_access" {
  description = "Enable private access to EKS API endpoint from within the VPC"
  type        = bool
  default     = true
}

variable "cluster_enabled_log_types" {
  description = "EKS control plane log types to send to CloudWatch (Checkov CKV_AWS_37)"
  type        = list(string)
  default     = ["api", "audit", "authenticator", "controllerManager", "scheduler"]
}

variable "cluster_log_retention_days" {
  description = "CloudWatch log group retention for EKS control plane logs (days)"
  type        = number
  default     = 90

  validation {
    condition     = contains([1, 3, 5, 7, 14, 30, 60, 90, 120, 150, 180, 365, 400, 545, 731, 1827, 3653], var.cluster_log_retention_days)
    error_message = "log_retention_days must be a valid CloudWatch retention value."
  }
}

# ── EKS Node Groups ───────────────────────────────────────────────────────────

variable "node_group_instance_types" {
  description = "EC2 instance types for the managed node group"
  type        = list(string)
  default     = ["t3.small"]   # t3.small: 2 vCPU, 2 GB — AWS Free Tier eligible
}

variable "node_group_ami_type" {
  description = "AMI type for node group (AL2_x86_64 | AL2023_x86_64_STANDARD | BOTTLEROCKET_x86_64)"
  type        = string
  default     = "AL2023_x86_64_STANDARD"   # Amazon Linux 2023 — latest, supported

  validation {
    condition     = contains(["AL2_x86_64", "AL2023_x86_64_STANDARD", "BOTTLEROCKET_x86_64", "BOTTLEROCKET_ARM_64"], var.node_group_ami_type)
    error_message = "node_group_ami_type must be a valid EKS AMI type."
  }
}

variable "node_group_capacity_type" {
  description = "Node group capacity type (ON_DEMAND | SPOT). SPOT for dev cost savings."
  type        = string
  default     = "ON_DEMAND"

  validation {
    condition     = contains(["ON_DEMAND", "SPOT"], var.node_group_capacity_type)
    error_message = "node_group_capacity_type must be ON_DEMAND or SPOT."
  }
}

variable "node_group_min_size" {
  description = "Minimum number of nodes in the node group"
  type        = number
  default     = 1
}

variable "node_group_max_size" {
  description = "Maximum number of nodes in the node group"
  type        = number
  default     = 4
}

variable "node_group_desired_size" {
  description = "Desired number of nodes at cluster creation"
  type        = number
  default     = 2
}

variable "node_group_disk_size_gb" {
  description = "Root EBS volume size for each node (GB)"
  type        = number
  default     = 50
}

# ── ArgoCD ────────────────────────────────────────────────────────────────────

variable "argocd_namespace" {
  description = "Kubernetes namespace for ArgoCD"
  type        = string
  default     = "argocd"
}

variable "argocd_chart_version" {
  description = "Helm chart version for ArgoCD (argo/argo-cd)"
  type        = string
  default     = "7.7.23"  # Check https://artifacthub.io/packages/helm/argo/argo-cd
}

# ── Monitoring ────────────────────────────────────────────────────────────────

variable "monitoring_namespace" {
  description = "Kubernetes namespace for Grafana/Prometheus stack"
  type        = string
  default     = "monitoring"
}

# ── Security ──────────────────────────────────────────────────────────────────

variable "enable_secrets_encryption" {
  description = "Enable KMS encryption for Kubernetes secrets (Checkov CKV_AWS_58)"
  type        = bool
  default     = true
}

variable "kms_key_deletion_window_days" {
  description = "KMS key deletion window in days (7–30)"
  type        = number
  default     = 30

  validation {
    condition     = var.kms_key_deletion_window_days >= 7 && var.kms_key_deletion_window_days <= 30
    error_message = "kms_key_deletion_window_days must be between 7 and 30."
  }
}

variable "enable_guardduty" {
  description = "Enable AWS GuardDuty for the region (threat detection)"
  type        = bool
  default     = false   # Enable in prod; can incur cost
}

# ── Tagging ───────────────────────────────────────────────────────────────────

variable "additional_tags" {
  description = "Additional tags to apply to all taggable resources"
  type        = map(string)
  default     = {}
}
