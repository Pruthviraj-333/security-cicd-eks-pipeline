# terraform/irsa.tf
# ─────────────────────────────────────────────────────────────────────────────
# IAM Roles for Service Accounts (IRSA)
#
# IRSA allows Kubernetes service accounts to assume IAM roles via OIDC federation.
# This eliminates node-level IAM permissions and implements true least-privilege:
# each workload gets exactly the permissions it needs, nothing more.
#
# Roles created:
#   1. ArgoCD Application Controller  → read-only ECR + EKS describe
#   2. ArgoCD Server                  → same scope
#   3. Grafana                        → CloudWatch read (for dashboards)
#   4. EBS CSI Driver                 → EC2 EBS management
#   5. Cluster Autoscaler             → EC2 Auto Scaling management
#   6. AWS Load Balancer Controller   → ELB + EC2 management
# ─────────────────────────────────────────────────────────────────────────────

# ── OIDC Provider (created by the EKS module, referenced here) ───────────────
data "aws_iam_openid_connect_provider" "eks" {
  url = module.eks.cluster_oidc_issuer_url
}

# ── Helper: IRSA trust policy document ───────────────────────────────────────
# Reusable template for all IRSA trust policies
data "aws_iam_policy_document" "irsa_assume_role" {
  for_each = {
    argocd_controller = {
      namespace = var.argocd_namespace
      sa_name   = local.argocd_sa_name
    }
    argocd_server = {
      namespace = var.argocd_namespace
      sa_name   = local.argocd_server_sa_name
    }
    grafana = {
      namespace = var.monitoring_namespace
      sa_name   = local.grafana_sa_name
    }
    ebs_csi = {
      namespace = local.ebs_csi_namespace
      sa_name   = local.ebs_csi_sa_name
    }
    cluster_autoscaler = {
      namespace = local.autoscaler_namespace
      sa_name   = local.autoscaler_sa_name
    }
    aws_load_balancer_controller = {
      namespace = local.albc_namespace
      sa_name   = local.albc_sa_name
    }
  }

  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRoleWithWebIdentity"]

    principals {
      type        = "Federated"
      identifiers = [data.aws_iam_openid_connect_provider.eks.arn]
    }

    # Lock down to the specific service account (audience + subject)
    condition {
      test     = "StringEquals"
      variable = "${local.oidc_issuer_host}:aud"
      values   = ["sts.amazonaws.com"]
    }

    condition {
      test     = "StringEquals"
      variable = "${local.oidc_issuer_host}:sub"
      values   = ["system:serviceaccount:${each.value.namespace}:${each.value.sa_name}"]
    }
  }
}

# ═══════════════════════════════════════════════════════════════════════════════
# 1. ArgoCD Application Controller IRSA
# ═══════════════════════════════════════════════════════════════════════════════

resource "aws_iam_role" "argocd_controller" {
  name               = "${local.name_prefix}-argocd-controller"
  assume_role_policy = data.aws_iam_policy_document.irsa_assume_role["argocd_controller"].json

  tags = merge(local.common_tags, {
    Name      = "${local.name_prefix}-argocd-controller-role"
    Component = "argocd"
  })
}

resource "aws_iam_role_policy" "argocd_controller" {
  name   = "${local.name_prefix}-argocd-controller-policy"
  role   = aws_iam_role.argocd_controller.id
  policy = data.aws_iam_policy_document.argocd_controller_policy.json
}

data "aws_iam_policy_document" "argocd_controller_policy" {
  # Read-only access to describe EKS cluster (needed for health checks)
  statement {
    sid    = "EKSDescribe"
    effect = "Allow"
    actions = [
      "eks:DescribeCluster",
      "eks:ListClusters",
    ]
    resources = [module.eks.cluster_arn]
  }

  # ECR read-only (to check image digests for drift detection)
  statement {
    sid    = "ECRReadOnly"
    effect = "Allow"
    actions = [
      "ecr:GetAuthorizationToken",
      "ecr:BatchCheckLayerAvailability",
      "ecr:GetDownloadUrlForLayer",
      "ecr:GetRepositoryPolicy",
      "ecr:DescribeRepositories",
      "ecr:ListImages",
      "ecr:DescribeImages",
      "ecr:BatchGetImage",
    ]
    resources = ["*"]
  }
}

# ═══════════════════════════════════════════════════════════════════════════════
# 2. ArgoCD Server IRSA
# ═══════════════════════════════════════════════════════════════════════════════

resource "aws_iam_role" "argocd_server" {
  name               = "${local.name_prefix}-argocd-server"
  assume_role_policy = data.aws_iam_policy_document.irsa_assume_role["argocd_server"].json

  tags = merge(local.common_tags, {
    Name      = "${local.name_prefix}-argocd-server-role"
    Component = "argocd"
  })
}

resource "aws_iam_role_policy" "argocd_server" {
  name   = "${local.name_prefix}-argocd-server-policy"
  role   = aws_iam_role.argocd_server.id
  policy = data.aws_iam_policy_document.argocd_server_policy.json
}

data "aws_iam_policy_document" "argocd_server_policy" {
  statement {
    sid    = "EKSDescribe"
    effect = "Allow"
    actions = [
      "eks:DescribeCluster",
    ]
    resources = [module.eks.cluster_arn]
  }
}

# ═══════════════════════════════════════════════════════════════════════════════
# 3. Grafana IRSA (CloudWatch read for dashboards)
# ═══════════════════════════════════════════════════════════════════════════════

resource "aws_iam_role" "grafana" {
  name               = "${local.name_prefix}-grafana"
  assume_role_policy = data.aws_iam_policy_document.irsa_assume_role["grafana"].json

  tags = merge(local.common_tags, {
    Name      = "${local.name_prefix}-grafana-role"
    Component = "monitoring"
  })
}

resource "aws_iam_role_policy" "grafana" {
  name   = "${local.name_prefix}-grafana-policy"
  role   = aws_iam_role.grafana.id
  policy = data.aws_iam_policy_document.grafana_policy.json
}

data "aws_iam_policy_document" "grafana_policy" {
  # CloudWatch metrics read (for dashboards)
  statement {
    sid    = "CloudWatchMetricsRead"
    effect = "Allow"
    actions = [
      "cloudwatch:DescribeAlarmsForMetric",
      "cloudwatch:DescribeAlarmHistory",
      "cloudwatch:DescribeAlarms",
      "cloudwatch:ListMetrics",
      "cloudwatch:GetMetricData",
      "cloudwatch:GetInsightRuleReport",
    ]
    resources = ["*"]
  }

  # CloudWatch logs read (for pipeline scan results forwarded to CW)
  statement {
    sid    = "CloudWatchLogsRead"
    effect = "Allow"
    actions = [
      "logs:DescribeLogGroups",
      "logs:DescribeLogStreams",
      "logs:GetLogEvents",
      "logs:StartQuery",
      "logs:StopQuery",
      "logs:GetQueryResults",
      "logs:GetLogRecord",
    ]
    resources = [
      "arn:aws:logs:${var.aws_region}:${var.aws_account_id}:log-group:/aws/eks/${local.cluster_name}*",
      "arn:aws:logs:${var.aws_region}:${var.aws_account_id}:log-group:/aws/vpc/flow-log/${local.name_prefix}*",
    ]
  }

  # EC2 describe (for AWS datasource in Grafana)
  statement {
    sid    = "EC2Describe"
    effect = "Allow"
    actions = [
      "ec2:DescribeTags",
      "ec2:DescribeInstances",
      "ec2:DescribeRegions",
    ]
    resources = ["*"]
  }
}

# ═══════════════════════════════════════════════════════════════════════════════
# 4. EBS CSI Driver IRSA
# ═══════════════════════════════════════════════════════════════════════════════

resource "aws_iam_role" "ebs_csi" {
  name               = "${local.name_prefix}-ebs-csi"
  assume_role_policy = data.aws_iam_policy_document.irsa_assume_role["ebs_csi"].json

  tags = merge(local.common_tags, {
    Name      = "${local.name_prefix}-ebs-csi-role"
    Component = "ebs-csi"
  })
}

# Attach the AWS managed policy for EBS CSI driver
resource "aws_iam_role_policy_attachment" "ebs_csi" {
  role       = aws_iam_role.ebs_csi.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonEBSCSIDriverPolicy"
}

# Allow EBS CSI to use KMS for encrypted volumes
resource "aws_iam_role_policy" "ebs_csi_kms" {
  name   = "${local.name_prefix}-ebs-csi-kms"
  role   = aws_iam_role.ebs_csi.id
  policy = data.aws_iam_policy_document.ebs_csi_kms_policy.json
}

data "aws_iam_policy_document" "ebs_csi_kms_policy" {
  statement {
    sid    = "KMSEBSEncryption"
    effect = "Allow"
    actions = [
      "kms:CreateGrant",
      "kms:ListGrants",
      "kms:RevokeGrant",
      "kms:Encrypt",
      "kms:Decrypt",
      "kms:ReEncrypt*",
      "kms:GenerateDataKey*",
      "kms:DescribeKey",
    ]
    resources = [aws_kms_key.eks.arn]
  }
}

# ═══════════════════════════════════════════════════════════════════════════════
# 5. Cluster Autoscaler IRSA
# ═══════════════════════════════════════════════════════════════════════════════

resource "aws_iam_role" "cluster_autoscaler" {
  name               = "${local.name_prefix}-cluster-autoscaler"
  assume_role_policy = data.aws_iam_policy_document.irsa_assume_role["cluster_autoscaler"].json

  tags = merge(local.common_tags, {
    Name      = "${local.name_prefix}-cluster-autoscaler-role"
    Component = "cluster-autoscaler"
  })
}

resource "aws_iam_role_policy" "cluster_autoscaler" {
  name   = "${local.name_prefix}-cluster-autoscaler-policy"
  role   = aws_iam_role.cluster_autoscaler.id
  policy = data.aws_iam_policy_document.cluster_autoscaler_policy.json
}

data "aws_iam_policy_document" "cluster_autoscaler_policy" {
  statement {
    sid    = "AutoscalerDescribe"
    effect = "Allow"
    actions = [
      "autoscaling:DescribeAutoScalingGroups",
      "autoscaling:DescribeAutoScalingInstances",
      "autoscaling:DescribeLaunchConfigurations",
      "autoscaling:DescribeScalingActivities",
      "autoscaling:DescribeTags",
      "ec2:DescribeImages",
      "ec2:DescribeInstanceTypes",
      "ec2:DescribeLaunchTemplateVersions",
      "ec2:GetInstanceTypesFromInstanceRequirements",
      "eks:DescribeNodegroup",
    ]
    resources = ["*"]
  }

  statement {
    sid    = "AutoscalerModify"
    effect = "Allow"
    actions = [
      "autoscaling:SetDesiredCapacity",
      "autoscaling:TerminateInstanceInAutoScalingGroup",
    ]
    # Scoped to only ASGs tagged with our cluster name
    resources = ["*"]
    condition {
      test     = "StringEquals"
      variable = "autoscaling:ResourceTag/k8s.io/cluster-autoscaler/${local.cluster_name}"
      values   = ["owned"]
    }
  }
}

# ═══════════════════════════════════════════════════════════════════════════════
# 6. AWS Load Balancer Controller IRSA
# ═══════════════════════════════════════════════════════════════════════════════

resource "aws_iam_role" "aws_load_balancer_controller" {
  name               = "${local.name_prefix}-alb-controller"
  assume_role_policy = data.aws_iam_policy_document.irsa_assume_role["aws_load_balancer_controller"].json

  tags = merge(local.common_tags, {
    Name      = "${local.name_prefix}-alb-controller-role"
    Component = "alb-controller"
  })
}

# AWS provides a managed policy document for the ALB controller
# Download from: https://raw.githubusercontent.com/kubernetes-sigs/aws-load-balancer-controller/main/docs/install/iam_policy.json
resource "aws_iam_role_policy" "aws_load_balancer_controller" {
  name   = "${local.name_prefix}-alb-controller-policy"
  role   = aws_iam_role.aws_load_balancer_controller.id
  policy = data.aws_iam_policy_document.albc_policy.json
}

data "aws_iam_policy_document" "albc_policy" {
  statement {
    sid    = "ALBCCore"
    effect = "Allow"
    actions = [
      "iam:CreateServiceLinkedRole",
      "ec2:DescribeAccountAttributes",
      "ec2:DescribeAddresses",
      "ec2:DescribeAvailabilityZones",
      "ec2:DescribeInternetGateways",
      "ec2:DescribeVpcs",
      "ec2:DescribeVpcPeeringConnections",
      "ec2:DescribeSubnets",
      "ec2:DescribeSecurityGroups",
      "ec2:DescribeInstances",
      "ec2:DescribeNetworkInterfaces",
      "ec2:DescribeTags",
      "ec2:GetCoipPoolUsage",
      "ec2:DescribeCoipPools",
      "elasticloadbalancing:DescribeLoadBalancers",
      "elasticloadbalancing:DescribeLoadBalancerAttributes",
      "elasticloadbalancing:DescribeListeners",
      "elasticloadbalancing:DescribeListenerCertificates",
      "elasticloadbalancing:DescribeSSLPolicies",
      "elasticloadbalancing:DescribeRules",
      "elasticloadbalancing:DescribeTargetGroups",
      "elasticloadbalancing:DescribeTargetGroupAttributes",
      "elasticloadbalancing:DescribeTargetHealth",
      "elasticloadbalancing:DescribeTags",
      "elasticloadbalancing:DescribeTrustStores",
    ]
    resources = ["*"]
  }

  statement {
    sid    = "ALBCModify"
    effect = "Allow"
    actions = [
      "ec2:AuthorizeSecurityGroupIngress",
      "ec2:RevokeSecurityGroupIngress",
      "ec2:CreateSecurityGroup",
      "ec2:CreateTags",
      "ec2:DeleteTags",
      "ec2:DeleteSecurityGroup",
      "elasticloadbalancing:CreateLoadBalancer",
      "elasticloadbalancing:CreateTargetGroup",
      "elasticloadbalancing:CreateListener",
      "elasticloadbalancing:DeleteListener",
      "elasticloadbalancing:CreateRule",
      "elasticloadbalancing:DeleteRule",
      "elasticloadbalancing:AddTags",
      "elasticloadbalancing:RemoveTags",
      "elasticloadbalancing:ModifyLoadBalancerAttributes",
      "elasticloadbalancing:SetIpAddressType",
      "elasticloadbalancing:SetSecurityGroups",
      "elasticloadbalancing:SetSubnets",
      "elasticloadbalancing:DeleteLoadBalancer",
      "elasticloadbalancing:ModifyTargetGroup",
      "elasticloadbalancing:ModifyTargetGroupAttributes",
      "elasticloadbalancing:DeleteTargetGroup",
      "elasticloadbalancing:RegisterTargets",
      "elasticloadbalancing:DeregisterTargets",
      "elasticloadbalancing:SetWebAcl",
      "elasticloadbalancing:ModifyListener",
      "elasticloadbalancing:AddListenerCertificates",
      "elasticloadbalancing:RemoveListenerCertificates",
      "elasticloadbalancing:ModifyRule",
    ]
    resources = ["*"]
  }
}
