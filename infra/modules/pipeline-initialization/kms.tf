# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: MIT-0

# ─────────────────────────────────────────────────────────────────────────────
# KMS Key for S3 Buckets
# ─────────────────────────────────────────────────────────────────────────────

data "aws_iam_policy_document" "s3_encryption_key" {
  #checkov:skip=CKV_AWS_109: "KMS key policy: resource "*" is self-referential (this key) and principal is account root for IAM delegation"
  #checkov:skip=CKV_AWS_111: "KMS key policy: resource "*" is self-referential (this key) and principal is account root for IAM delegation"
  #checkov:skip=CKV_AWS_356: "KMS key policies require resource "*" which refers to the key itself"

  statement {
    sid    = "Enable IAM User Permissions"
    effect = "Allow"

    principals {
      type        = "AWS"
      identifiers = ["arn:aws:iam::${data.aws_caller_identity.current.account_id}:root"]
    }

    actions   = ["kms:*"]
    resources = ["*"]
  }
}

# KMS Key for S3 bucket encryption
resource "aws_kms_key" "s3_encryption" {
  description             = "KMS key for ${var.pipeline_name} S3 bucket encryption"
  deletion_window_in_days = 7
  enable_key_rotation     = true

  policy = data.aws_iam_policy_document.s3_encryption_key.json

  tags = local.common_tags
}

resource "aws_kms_alias" "s3_encryption" {
  name          = "alias/${var.pipeline_name}-${var.environment}-s3"
  target_key_id = aws_kms_key.s3_encryption.key_id
}

# ─────────────────────────────────────────────────────────────────────────────
# KMS Key for CloudWatch Logs encryption
# ─────────────────────────────────────────────────────────────────────────────

data "aws_iam_policy_document" "cloudwatch_kms_key" {
  #checkov:skip=CKV_AWS_109: "KMS key policy: resource "*" is self-referential (this key) and principal is account root for IAM delegation"
  #checkov:skip=CKV_AWS_111: "KMS key policy: resource "*" is self-referential (this key) and principal is account root for IAM delegation"
  #checkov:skip=CKV_AWS_356: "KMS key policies require resource "*" which refers to the key itself"

  statement {
    sid    = "EnableKeyManagement"
    effect = "Allow"

    principals {
      type        = "AWS"
      identifiers = ["arn:aws:iam::${data.aws_caller_identity.current.account_id}:root"]
    }

    actions   = ["kms:*"]
    resources = ["*"]
  }

  statement {
    sid    = "AllowCloudWatchLogs"
    effect = "Allow"

    principals {
      type        = "Service"
      identifiers = ["logs.${var.region}.amazonaws.com"]
    }

    actions = [
      "kms:Encrypt*",
      "kms:Decrypt*",
      "kms:ReEncrypt*",
      "kms:GenerateDataKey*",
      "kms:Describe*",
    ]
    resources = ["*"]

    condition {
      test     = "ArnLike"
      variable = "kms:EncryptionContext:aws:logs:arn"
      values   = ["arn:aws:logs:${var.region}:${data.aws_caller_identity.current.account_id}:log-group:*"]
    }
  }
}

resource "aws_kms_key" "cloudwatch" {
  description             = "KMS key for CloudWatch Logs - ${var.pipeline_name}-${var.environment}"
  deletion_window_in_days = 7
  enable_key_rotation     = true
  policy                  = data.aws_iam_policy_document.cloudwatch_kms_key.json

  tags = local.common_tags
}

resource "aws_kms_alias" "cloudwatch" {
  name          = "alias/${var.pipeline_name}-${var.environment}-cloudwatch"
  target_key_id = aws_kms_key.cloudwatch.key_id
}
