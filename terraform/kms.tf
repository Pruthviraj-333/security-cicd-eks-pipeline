# terraform/kms.tf
# ─────────────────────────────────────────────────────────────────────────────
# KMS key for:
#   - EKS secrets encryption (CKV_AWS_58)
#   - EBS volume encryption on node groups (CKV_AWS_337)
#   - CloudWatch log group encryption
# ─────────────────────────────────────────────────────────────────────────────

data "aws_caller_identity" "current" {}

# ── EKS / General KMS Key ────────────────────────────────────────────────────
resource "aws_kms_key" "eks" {
  description              = "KMS key for EKS secrets encryption and EBS volumes — ${local.name_prefix}"
  deletion_window_in_days  = var.kms_key_deletion_window_days
  enable_key_rotation      = true   # CKV_AWS_7 — automatic annual rotation
  multi_region             = false

  policy = data.aws_iam_policy_document.kms_eks_policy.json

  tags = merge(local.common_tags, {
    Name = "${local.name_prefix}-eks-kms-key"
  })
}

resource "aws_kms_alias" "eks" {
  name          = "alias/${local.name_prefix}-eks"
  target_key_id = aws_kms_key.eks.key_id
}

data "aws_iam_policy_document" "kms_eks_policy" {
  # Root account full access (required by AWS — without this, key becomes unmanageable)
  statement {
    sid     = "RootAccountFullAccess"
    effect  = "Allow"
    principals {
      type        = "AWS"
      identifiers = ["arn:aws:iam::${var.aws_account_id}:root"]
    }
    actions   = ["kms:*"]
    resources = ["*"]
  }

  # Allow EKS service to use the key for secrets encryption
  statement {
    sid    = "EKSSecretsEncryption"
    effect = "Allow"
    principals {
      type        = "Service"
      identifiers = ["eks.amazonaws.com"]
    }
    actions = [
      "kms:Encrypt",
      "kms:Decrypt",
      "kms:ReEncrypt*",
      "kms:GenerateDataKey*",
      "kms:DescribeKey",
    ]
    resources = ["*"]
  }

  # Allow EC2 to use the key for EBS encryption
  statement {
    sid    = "EC2EBSEncryption"
    effect = "Allow"
    principals {
      type        = "Service"
      identifiers = ["ec2.amazonaws.com"]
    }
    actions = [
      "kms:Encrypt",
      "kms:Decrypt",
      "kms:ReEncrypt*",
      "kms:GenerateDataKey*",
      "kms:CreateGrant",
      "kms:DescribeKey",
    ]
    resources = ["*"]
  }

  # Allow CloudWatch logs to use the key
  statement {
    sid    = "CloudWatchLogsEncryption"
    effect = "Allow"
    principals {
      type        = "Service"
      identifiers = ["logs.${var.aws_region}.amazonaws.com"]
    }
    actions = [
      "kms:Encrypt",
      "kms:Decrypt",
      "kms:ReEncrypt*",
      "kms:GenerateDataKey*",
      "kms:DescribeKey",
    ]
    resources = ["*"]
    condition {
      test     = "ArnLike"
      variable = "kms:EncryptionContext:aws:logs:arn"
      values   = ["arn:aws:logs:${var.aws_region}:${var.aws_account_id}:*"]
    }
  }

  # Allow node role to use the key for EBS CSI driver
  statement {
    sid    = "NodeRoleEBSAccess"
    effect = "Allow"
    principals {
      type        = "AWS"
      identifiers = ["arn:aws:iam::${var.aws_account_id}:role/${local.name_prefix}-ebs-csi"]
    }
    actions = [
      "kms:Encrypt",
      "kms:Decrypt",
      "kms:ReEncrypt*",
      "kms:GenerateDataKey*",
      "kms:CreateGrant",
      "kms:DescribeKey",
    ]
    resources = ["*"]
  }

  # Allow Auto Scaling to use the key for EBS encryption
  statement {
    sid    = "AutoScalingEBSEncryption"
    effect = "Allow"
    principals {
      type        = "AWS"
      identifiers = ["arn:aws:iam::${var.aws_account_id}:role/aws-service-role/autoscaling.amazonaws.com/AWSServiceRoleForAutoScaling"]
    }
    actions = [
      "kms:Encrypt",
      "kms:Decrypt",
      "kms:ReEncrypt*",
      "kms:GenerateDataKey*",
      "kms:CreateGrant",
      "kms:DescribeKey"
    ]
    resources = ["*"]
  }
}
