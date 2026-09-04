# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: MIT-0


resource "aws_kms_key" "ecr" {
  description             = "KMS key for ECR encryption "
  deletion_window_in_days = 10
  enable_key_rotation     = true
  policy                  = data.aws_iam_policy_document.kms_key.json
}

resource "aws_kms_alias" "ecr" {
  name          = "alias/ecr-${local.pipeline_name}-${local.environment}"
  target_key_id = aws_kms_key.ecr.key_id
}

# ECR Repositories for batch steps (only when not provided externally)
resource "aws_ecr_repository" "batch_repos" {
  for_each = { for step in local.batch_steps : step.name => step if step.ecr_repository_url == null }

  name                 = "${local.pipeline_name}-${local.environment}-${each.key}"
  image_tag_mutability = "IMMUTABLE_WITH_EXCLUSION"

  encryption_configuration {
    encryption_type = "KMS"
    kms_key         = aws_kms_alias.ecr.target_key_arn
  }

  image_scanning_configuration {
    scan_on_push = var.ecr_scan_on_push
  }

  image_tag_mutability_exclusion_filter {
    filter      = "latest*"
    filter_type = "WILDCARD"
  }

  force_delete = var.ecr_force_delete

  tags = local.common_tags
}

# ECR lifecycle policy — stacked rules (lower rulePriority wins first)
locals {
  ecr_lifecycle_rules = concat(
    # Priority 1: always protect the exact 'latest' tag
    [{
      rulePriority = 1
      description  = "Always keep the image tagged 'latest'"
      selection = {
        tagStatus      = "tagged"
        tagPatternList = ["latest"]
        countType      = "imageCountMoreThan"
        countNumber    = 1
      }
      action = { type = "expire" }
    }],
    var.ecr_keep_tagged_count == null ? [] : [{
      rulePriority = 2
      description  = "Keep the ${var.ecr_keep_tagged_count} most recent tagged images (any tag)"
      selection = {
        tagStatus      = "tagged"
        tagPatternList = ["*"]
        countType      = "imageCountMoreThan"
        countNumber    = var.ecr_keep_tagged_count
      }
      action = { type = "expire" }
    }],
    var.ecr_expire_untagged_days == null ? [] : [{
      rulePriority = 3
      description  = "Expire untagged images older than ${var.ecr_expire_untagged_days} days"
      selection = {
        tagStatus   = "untagged"
        countType   = "sinceImagePushed"
        countUnit   = "days"
        countNumber = var.ecr_expire_untagged_days
      }
      action = { type = "expire" }
    }],
    var.ecr_archive_unpulled_days == null ? [] : [{
      rulePriority = 4
      description  = "Archive images not pulled in ${var.ecr_archive_unpulled_days} days"
      selection = {
        tagStatus   = "any"
        countType   = "sinceImagePulled"
        countUnit   = "days"
        countNumber = var.ecr_archive_unpulled_days
      }
      action = {
        type               = "transition"
        targetStorageClass = "archive"
      }
    }],
  )

  ecr_lifecycle_policy_json = length(local.ecr_lifecycle_rules) > 0 ? jsonencode({ rules = local.ecr_lifecycle_rules }) : null
}

resource "aws_ecr_lifecycle_policy" "batch_repos" {
  for_each = local.ecr_lifecycle_policy_json == null ? {} : aws_ecr_repository.batch_repos

  repository = each.value.name
  policy     = local.ecr_lifecycle_policy_json
}
