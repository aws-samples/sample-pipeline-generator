# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: MIT-0

locals {
  common_tags = merge(var.tags, {
    Pipeline    = var.pipeline_name
    Environment = var.environment
    DeployedBy  = "OpenTofu"
    Owner       = "workflow-platform"
  })

  # Per-bucket Intelligent-Tiering config with defaults for every created bucket
  s3_it_config = {
    for bucket_name in var.buckets : bucket_name => lookup(
      var.s3_lifecycle_rules,
      bucket_name,
      { enabled = true, archive_access_days = null, deep_archive_access_days = null }
    )
  }

  # Buckets with Intelligent-Tiering enabled (lifecycle transition to IT class)
  s3_it_enabled_buckets = { for bucket_name, config in local.s3_it_config : bucket_name => config if config.enabled }

  # Buckets that additionally opt in to Archive / Deep Archive tiers
  s3_it_archive_buckets = {
    for bucket_name, config in local.s3_it_enabled_buckets :
    bucket_name => config
    if config.archive_access_days != null || config.deep_archive_access_days != null
  }
}

# S3 Buckets
resource "aws_s3_bucket" "buckets" {
  # Checkov struggles with those checks, while they are indeed enforced in the code
  #checkov:skip=CKV2_AWS_6: "Public access block is defined in aws_s3_bucket_public_access_block.buckets"
  #checkov:skip=CKV2_AWS_61: "Ensure that an S3 bucket has a lifecycle configuration"
  #checkov:skip=CKV2_AWS_62: "No downstream consumers of bucket events"
  #checkov:skip=CKV_AWS_145: "KMS encryption is defined in aws_s3_bucket_server_side_encryption_configuration.buckets"
  #checkov:skip=CKV_AWS_21: "Versioning is defined in aws_s3_bucket_versioning.buckets"
  for_each      = var.buckets
  bucket        = "${var.pipeline_name}-${var.environment}-${each.value}-${data.aws_caller_identity.current.account_id}"
  tags          = local.common_tags
  force_destroy = var.s3_force_destroy
}

resource "aws_s3_bucket_public_access_block" "buckets" {
  for_each = var.buckets
  bucket   = aws_s3_bucket.buckets[each.key].id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_versioning" "buckets" {
  for_each = var.buckets
  bucket   = aws_s3_bucket.buckets[each.key].id
  versioning_configuration {
    status = "Enabled"
  }
}

# S3 Bucket Encryption
resource "aws_s3_bucket_server_side_encryption_configuration" "buckets" {
  for_each = var.buckets
  bucket   = aws_s3_bucket.buckets[each.key].id

  rule {
    apply_server_side_encryption_by_default {
      kms_master_key_id = aws_kms_key.s3_encryption.arn
      sse_algorithm     = "aws:kms"
    }
  }
}

# S3 lifecycle rule: transition objects to INTELLIGENT_TIERING storage class at day 0
resource "aws_s3_bucket_lifecycle_configuration" "buckets" {
  for_each = local.s3_it_enabled_buckets

  bucket = aws_s3_bucket.buckets[each.key].id

  rule {
    id     = "intelligent-tiering"
    status = "Enabled"

    filter {}

    transition {
      days          = 0
      storage_class = "INTELLIGENT_TIERING"
    }
  }

  # Abort incomplete multipart uploads to avoid paying for orphaned parts
  rule {
    id     = "abort-incomplete-multipart-upload"
    status = "Enabled"

    filter {}

    abort_incomplete_multipart_upload {
      days_after_initiation = 7
    }
  }
}

# S3 Intelligent-Tiering archive configuration (opt-in Archive / Deep Archive tiers)
resource "aws_s3_bucket_intelligent_tiering_configuration" "buckets" {
  for_each = local.s3_it_archive_buckets

  bucket = aws_s3_bucket.buckets[each.key].id
  name   = "EntireBucket"

  dynamic "tiering" {
    for_each = each.value.archive_access_days == null ? [] : [each.value.archive_access_days]
    content {
      access_tier = "ARCHIVE_ACCESS"
      days        = tiering.value
    }
  }

  dynamic "tiering" {
    for_each = each.value.deep_archive_access_days == null ? [] : [each.value.deep_archive_access_days]
    content {
      access_tier = "DEEP_ARCHIVE_ACCESS"
      days        = tiering.value
    }
  }
}
