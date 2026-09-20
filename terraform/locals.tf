# terraform/locals.tf
# ─────────────────────────────────────────────────────────────────────────────
# Common local values derived from variables — keeps main resource files clean
# ─────────────────────────────────────────────────────────────────────────────

locals {
  # Standard name prefix for all resources
  name_prefix = "${var.project_name}-${var.environment}"

  # Cluster full name (used in IRSA trust policies, CloudWatch log groups, etc.)
  cluster_name = "${local.name_prefix}-${var.cluster_name}"

  # Merged common tags — applied on top of provider default_tags where needed
  common_tags = {
    Project     = var.project_name
    Environment = var.environment
    Owner       = var.owner
    ManagedBy   = "terraform"
  }

  # IRSA subject prefix for this cluster's OIDC provider
  # Format: system:serviceaccount:<namespace>:<service-account-name>
  oidc_issuer_url = module.eks.cluster_oidc_issuer_url

  # Strip https:// prefix for use in IAM trust policy conditions
  oidc_issuer_host = replace(local.oidc_issuer_url, "https://", "")

  # Pilot services and their namespaces
  pilot_services = {
    frontend        = "default"
    cartservice     = "default"
    checkoutservice = "default"
  }

  # ArgoCD IRSA configuration
  argocd_sa_name        = "argocd-application-controller"
  argocd_server_sa_name = "argocd-server"

  # Grafana IRSA configuration
  grafana_sa_name = "grafana"

  # AWS Load Balancer Controller IRSA
  albc_sa_name        = "aws-load-balancer-controller"
  albc_namespace      = "kube-system"

  # Cluster Autoscaler IRSA
  autoscaler_sa_name  = "cluster-autoscaler"
  autoscaler_namespace = "kube-system"

  # EBS CSI Driver IRSA
  ebs_csi_sa_name     = "ebs-csi-controller-sa"
  ebs_csi_namespace   = "kube-system"
}
