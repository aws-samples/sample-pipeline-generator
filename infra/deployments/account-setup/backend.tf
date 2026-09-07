# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: MIT-0

resource "aws_s3_bucket" "terraform_state" {
  #checkov:skip=CKV_AWS_18: Access logging not needed; state writes are audited via CloudTrail.
  #checkov:skip=CKV_AWS_144: Cross-region replication would require a replica bucket that itself depends on this bootstrap; out of scope.
  #checkov:skip=CKV2_AWS_62: No downstream consumers of state-bucket events.
  bucket = local.tf_state_bucket_name
}

resource "aws_s3_bucket_versioning" "terraform_state" {
  bucket = aws_s3_bucket.terraform_state.id
  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_lifecycle_configuration" "terraform_state" {
  bucket = aws_s3_bucket.terraform_state.id

  # Current versions are not affected by `noncurrent_version_expiration`, so the
  # live state file is retained indefinitely.
  rule {
    id     = "expire-noncurrent-versions-after-90-days"
    status = "Enabled"

    filter {}

    noncurrent_version_expiration {
      noncurrent_days = 90
    }
  }

  # Clean up any abandoned multipart uploads to avoid orphaned storage costs.
  rule {
    id     = "abort-incomplete-multipart-uploads-after-7-days"
    status = "Enabled"

    filter {}

    abort_incomplete_multipart_upload {
      days_after_initiation = 7
    }
  }

  # Versioning must be enabled before a noncurrent-version rule is applied.
  depends_on = [aws_s3_bucket_versioning.terraform_state]
}

resource "aws_s3_bucket_server_side_encryption_configuration" "terraform_state" {
  bucket = aws_s3_bucket.terraform_state.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm     = "aws:kms"
      kms_master_key_id = aws_kms_key.s3_encryption.arn
    }
  }
}

resource "aws_s3_bucket_public_access_block" "terraform_state" {
  bucket = aws_s3_bucket.terraform_state.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

data "aws_iam_policy_document" "terraform_state" {
  dynamic "statement" {
    for_each = length(var.state_backend_principals) > 0 ? [1] : []

    content {
      sid    = "AllowStateBackendRolesBucketAccess"
      effect = "Allow"

      principals {
        type        = "AWS"
        identifiers = var.state_backend_principals
      }

      actions = [
        "s3:ListBucket",
        "s3:GetBucketVersioning",
      ]
      resources = [aws_s3_bucket.terraform_state.arn]
    }
  }

  dynamic "statement" {
    for_each = length(var.state_backend_principals) > 0 ? [1] : []

    content {
      sid    = "AllowStateBackendRolesObjectAccess"
      effect = "Allow"

      principals {
        type        = "AWS"
        identifiers = var.state_backend_principals
      }

      actions = [
        "s3:GetObject",
        "s3:PutObject",
        "s3:DeleteObject",
      ]
      resources = ["${aws_s3_bucket.terraform_state.arn}/*"]
    }
  }

  statement {
    sid    = "DenyInsecureTransport"
    effect = "Deny"

    principals {
      type        = "*"
      identifiers = ["*"]
    }

    actions = ["s3:*"]
    resources = [
      aws_s3_bucket.terraform_state.arn,
      "${aws_s3_bucket.terraform_state.arn}/*",
    ]

    condition {
      test     = "Bool"
      variable = "aws:SecureTransport"
      values   = ["false"]
    }
  }
}

resource "aws_s3_bucket_policy" "terraform_state" {
  bucket = aws_s3_bucket.terraform_state.id
  policy = data.aws_iam_policy_document.terraform_state.json
}

data "aws_iam_policy_document" "s3_encryption_key" {
  #checkov:skip=CKV_AWS_109:KMS key policy uses kms:* which is standard - resource '*' refers to the key itself
  #checkov:skip=CKV_AWS_111:KMS key policy uses kms:* which is standard - resource '*' refers to the key itself
  #checkov:skip=CKV_AWS_356:KMS key policy resource '*' refers to the key itself, not all AWS resources

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

  dynamic "statement" {
    for_each = length(var.state_backend_principals) > 0 ? [1] : []

    content {
      sid    = "AllowStateBackendRolesUseOfKey"
      effect = "Allow"

      principals {
        type        = "AWS"
        identifiers = var.state_backend_principals
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
  }
}

# KMS Key for S3 bucket encryption
resource "aws_kms_key" "s3_encryption" {
  description             = "KMS key for OpenTofu Backend S3 bucket encryption"
  deletion_window_in_days = 7
  enable_key_rotation     = true

  policy = data.aws_iam_policy_document.s3_encryption_key.json
}

resource "aws_kms_alias" "s3_encryption" {
  name          = "alias/tf-backend-${var.environment}-s3"
  target_key_id = aws_kms_key.s3_encryption.key_id
}
