# terraform/outputs.tf
# ─────────────────────────────────────────────────────────────────────────────
# Outputs used by:
#   - GitHub Actions (Stages 6–8) via terraform output -json
#   - Local developers (kubectl, cosign verify, etc.)
#   - docs/architecture.md references
# ─────────────────────────────────────────────────────────────────────────────

# ── VPC ──────────────────────────────────────────────────────────────────────
output "vpc_id" {
  description = "ID of the VPC"
  value       = aws_vpc.main.id
}

output "vpc_cidr" {
  description = "CIDR block of the VPC"
  value       = aws_vpc.main.cidr_block
}

output "private_subnet_ids" {
  description = "IDs of private subnets (EKS nodes)"
  value       = aws_subnet.private[*].id
}

output "public_subnet_ids" {
  description = "IDs of public subnets (ALB, NAT GW)"
  value       = aws_subnet.public[*].id
}

# ── EKS Cluster ───────────────────────────────────────────────────────────────
output "cluster_name" {
  description = "EKS cluster name"
  value       = module.eks.cluster_name
}

output "cluster_endpoint" {
  description = "EKS API server endpoint"
  value       = module.eks.cluster_endpoint
  sensitive   = true
}

output "cluster_ca_certificate" {
  description = "Base64-encoded cluster CA certificate"
  value       = module.eks.cluster_certificate_authority_data
  sensitive   = true
}

output "cluster_arn" {
  description = "EKS cluster ARN"
  value       = module.eks.cluster_arn
}

output "cluster_oidc_issuer_url" {
  description = "OIDC issuer URL for the cluster (used for IRSA)"
  value       = module.eks.cluster_oidc_issuer_url
}

output "cluster_oidc_provider_arn" {
  description = "ARN of the OIDC provider for the cluster"
  value       = data.aws_iam_openid_connect_provider.eks.arn
}

output "cluster_version" {
  description = "Kubernetes version running on the cluster"
  value       = module.eks.cluster_version
}

# ── kubectl config command ────────────────────────────────────────────────────
output "kubeconfig_command" {
  description = "Run this command to configure kubectl for the cluster"
  value       = "aws eks update-kubeconfig --name ${module.eks.cluster_name} --region ${var.aws_region}"
}

# ── KMS ───────────────────────────────────────────────────────────────────────
output "kms_key_arn" {
  description = "ARN of the KMS key used for EKS secrets encryption and EBS"
  value       = aws_kms_key.eks.arn
}

output "kms_key_id" {
  description = "ID of the KMS key"
  value       = aws_kms_key.eks.key_id
}

# ── IRSA Role ARNs (referenced in GitHub Actions workflows) ──────────────────
output "irsa_argocd_controller_arn" {
  description = "IAM role ARN for ArgoCD application controller (IRSA)"
  value       = aws_iam_role.argocd_controller.arn
}

output "irsa_argocd_server_arn" {
  description = "IAM role ARN for ArgoCD server (IRSA)"
  value       = aws_iam_role.argocd_server.arn
}

output "irsa_grafana_arn" {
  description = "IAM role ARN for Grafana (IRSA — CloudWatch read)"
  value       = aws_iam_role.grafana.arn
}

output "irsa_ebs_csi_arn" {
  description = "IAM role ARN for EBS CSI driver (IRSA)"
  value       = aws_iam_role.ebs_csi.arn
}

output "irsa_cluster_autoscaler_arn" {
  description = "IAM role ARN for Cluster Autoscaler (IRSA)"
  value       = aws_iam_role.cluster_autoscaler.arn
}

output "irsa_alb_controller_arn" {
  description = "IAM role ARN for AWS Load Balancer Controller (IRSA)"
  value       = aws_iam_role.aws_load_balancer_controller.arn
}

# ── ArgoCD ────────────────────────────────────────────────────────────────────
output "argocd_namespace" {
  description = "Kubernetes namespace where ArgoCD is installed"
  value       = var.argocd_namespace
}

output "argocd_server_service" {
  description = "Command to port-forward ArgoCD server UI locally"
  value       = "kubectl port-forward svc/argocd-server -n ${var.argocd_namespace} 8080:443"
}

output "argocd_initial_password_command" {
  description = "Command to retrieve the initial ArgoCD admin password"
  value       = "kubectl -n ${var.argocd_namespace} get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d"
  sensitive   = false   # This is just a kubectl command, not the secret itself
}

# ── Region / Account ──────────────────────────────────────────────────────────
output "aws_region" {
  description = "AWS region where infrastructure is deployed"
  value       = var.aws_region
}

output "aws_account_id" {
  description = "AWS account ID"
  value       = var.aws_account_id
  sensitive   = true
}
