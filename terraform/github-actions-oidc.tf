# terraform/github-actions-oidc.tf
# ─────────────────────────────────────────────────────────────────────────────
# IAM Role for GitHub Actions OIDC authentication
#
# This allows GitHub Actions workflows to assume an IAM role via OIDC
# WITHOUT storing any AWS access keys as GitHub Secrets.
#
# The trust policy is scoped to:
#   - Specific repository: Pruthviraj-333/security-cicd-eks-pipeline
#   - Specific branches: main only
#   - Specific workflow files (optional — further scoping possible)
#
# Used by: stage6-gitops-deploy.yml, stage7-drift-detection.yml
# ─────────────────────────────────────────────────────────────────────────────

# ── GitHub OIDC Provider (one per AWS account — idempotent) ──────────────────
resource "aws_iam_openid_connect_provider" "github_actions" {
  url = "https://token.actions.githubusercontent.com"

  client_id_list = ["sts.amazonaws.com"]

  # GitHub's OIDC thumbprint — stable, but verify at:
  # https://docs.github.com/en/actions/deployment/security-hardening-your-deployments/configuring-openid-connect-in-amazon-web-services
  thumbprint_list = [
    "6938fd4d98bab03faadb97b34396831e3780aea1",
    "1c58a3a8518e8759bf075b76b750d4f2df264fcd",
  ]

  tags = merge(local.common_tags, {
    Name = "github-actions-oidc-provider"
  })
}

# ── Deploy IAM Role ───────────────────────────────────────────────────────────
resource "aws_iam_role" "github_actions_deploy" {
  name               = "${local.name_prefix}-github-actions-deploy"
  assume_role_policy = data.aws_iam_policy_document.github_actions_trust.json
  max_session_duration = 3600   # 1 hour max

  tags = merge(local.common_tags, {
    Name      = "${local.name_prefix}-github-actions-deploy"
    Component = "ci-cd"
  })
}

data "aws_iam_policy_document" "github_actions_trust" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRoleWithWebIdentity"]

    principals {
      type        = "Federated"
      identifiers = [aws_iam_openid_connect_provider.github_actions.arn]
    }

    # Scope to GitHub's OIDC token audience
    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:aud"
      values   = ["sts.amazonaws.com"]
    }

    # Scope to specific repo + branch (sub claim format: repo:<owner>/<repo>:ref:refs/heads/<branch>)
    condition {
      test     = "StringLike"
      variable = "token.actions.githubusercontent.com:sub"
      values = [
        "repo:Pruthviraj-333/security-cicd-eks-pipeline:ref:refs/heads/main",
        "repo:Pruthviraj-333/security-cicd-eks-pipeline:environment:production",
      ]
    }
  }
}

# ── Deploy Role Policy (least-privilege) ─────────────────────────────────────
resource "aws_iam_role_policy" "github_actions_deploy" {
  name   = "${local.name_prefix}-github-actions-deploy-policy"
  role   = aws_iam_role.github_actions_deploy.id
  policy = data.aws_iam_policy_document.github_actions_deploy_policy.json
}

data "aws_iam_policy_document" "github_actions_deploy_policy" {
  # EKS: describe cluster (for kubectl auth)
  statement {
    sid    = "EKSDescribe"
    effect = "Allow"
    actions = [
      "eks:DescribeCluster",
      "eks:ListClusters",
      "eks:AccessKubernetesApi",
    ]
    resources = [module.eks.cluster_arn]
  }

  # ECR: read (image digest lookup for manifest updates)
  statement {
    sid    = "ECRRead"
    effect = "Allow"
    actions = [
      "ecr:GetAuthorizationToken",
      "ecr:BatchCheckLayerAvailability",
      "ecr:GetDownloadUrlForLayer",
      "ecr:DescribeImages",
      "ecr:BatchGetImage",
    ]
    resources = ["*"]
  }

  # CloudWatch: read (for Stage 7 drift detection checks)
  statement {
    sid    = "CloudWatchRead"
    effect = "Allow"
    actions = [
      "cloudwatch:GetMetricData",
      "cloudwatch:ListMetrics",
      "logs:GetLogEvents",
      "logs:DescribeLogGroups",
      "logs:DescribeLogStreams",
    ]
    resources = ["*"]
  }

  # Terraform state read (for plan-only CI jobs)
  # Only needed if using S3 remote state
  statement {
    sid    = "TerraformStateRead"
    effect = "Allow"
    actions = [
      "s3:GetObject",
      "s3:ListBucket",
    ]
    # Restrict to the specific tfstate bucket (update with your bucket name)
    resources = [
      "arn:aws:s3:::your-tfstate-bucket-name",
      "arn:aws:s3:::your-tfstate-bucket-name/*",
    ]
  }
}

# ── Output the role ARN for use in workflow files ────────────────────────────
output "github_actions_deploy_role_arn" {
  description = "ARN of the IAM role assumed by GitHub Actions for deploys (OIDC)"
  value       = aws_iam_role.github_actions_deploy.arn
}
