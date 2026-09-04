# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: MIT-0

variables {
  ecr_repositories    = ["copy-intermediate-to-output", "my-model"]
  allowed_account_ids = ["123456789012", "987654321098"]
  ecr_force_delete    = true
}

provider "aws" {
  region = "us-east-1"
}

run "test_ecr_repositories_created" {
  command = plan

  assert {
    condition     = length(aws_ecr_repository.batch_repos) == 2
    error_message = "Should create one ECR repository per entry in ecr_repositories"
  }

  assert {
    condition     = aws_ecr_repository.batch_repos["copy-intermediate-to-output"].name == "shared-copy-intermediate-to-output"
    error_message = "Repository name should be prefixed with 'shared-'"
  }

  assert {
    condition     = aws_ecr_repository.batch_repos["my-model"].name == "shared-my-model"
    error_message = "Repository name should be prefixed with 'shared-'"
  }
}

run "test_ecr_encryption" {
  command = plan

  assert {
    condition     = aws_ecr_repository.batch_repos["copy-intermediate-to-output"].encryption_configuration[0].encryption_type == "KMS"
    error_message = "ECR repositories must use KMS encryption"
  }

  assert {
    condition     = aws_ecr_repository.batch_repos["copy-intermediate-to-output"].image_scanning_configuration[0].scan_on_push == true
    error_message = "ECR scan-on-push must be enabled by default"
  }
}

run "test_ecr_immutability_with_exclusion" {
  command = plan

  assert {
    condition     = aws_ecr_repository.batch_repos["copy-intermediate-to-output"].image_tag_mutability == "IMMUTABLE_WITH_EXCLUSION"
    error_message = "Image tags should be immutable with exclusion for latest"
  }
}

run "test_kms_key_rotation" {
  command = plan

  assert {
    condition     = aws_kms_key.ecr.enable_key_rotation == true
    error_message = "KMS key must have automatic rotation enabled"
  }
}

run "test_kms_alias" {
  command = plan

  assert {
    condition     = aws_kms_alias.ecr.name == "alias/shared-ecr"
    error_message = "KMS alias should be 'alias/shared-ecr'"
  }
}

run "test_cross_account_ecr_policy" {
  command = plan

  assert {
    condition     = length(aws_ecr_repository_policy.cross_account_access) == 2
    error_message = "Cross-account policy should be attached to every repository"
  }
}

run "test_ecr_lifecycle_policy_default" {
  command = plan

  assert {
    condition     = length(aws_ecr_lifecycle_policy.batch_repos) == 2
    error_message = "Lifecycle policy should be attached to every repository by default"
  }

  assert {
    condition     = length(local.ecr_lifecycle_rules) == 4
    error_message = "Default lifecycle policy should contain 4 rules (always-keep-latest, keep tagged, expire untagged, archive unpulled)"
  }

  assert {
    condition     = local.ecr_lifecycle_rules[3].action.type == "transition" && local.ecr_lifecycle_rules[3].action.targetStorageClass == "archive"
    error_message = "The unpulled-images rule must TRANSITION to archive storage, never EXPIRE (ECR rejects sinceImagePulled + expire)"
  }
}

run "test_ssm_parameters_created" {
  command = plan

  assert {
    condition     = length(aws_ssm_parameter.ecr_batch_repositories) == 2
    error_message = "An SSM parameter should be created for each ECR repository"
  }

  assert {
    condition     = aws_ssm_parameter.ecr_batch_repositories["copy-intermediate-to-output"].name == "/pipelines/shared-copy-intermediate-to-output-ecr-url"
    error_message = "SSM parameter name must follow /pipelines/shared-<repo>-ecr-url pattern"
  }
}

run "test_ecr_lifecycle_policy_minimal" {
  command = plan

  variables {
    ecr_repositories          = ["single-repo"]
    allowed_account_ids       = ["123456789012"]
    ecr_keep_tagged_count     = null
    ecr_expire_untagged_days  = null
    ecr_archive_unpulled_days = null
  }

  assert {
    condition     = length(local.ecr_lifecycle_rules) == 1
    error_message = "Only the always-keep-latest rule should remain when all configurable rules are disabled"
  }

  assert {
    condition     = length(aws_ecr_lifecycle_policy.batch_repos) == 1
    error_message = "Lifecycle policy should still be attached because the always-keep-latest rule is unconditional"
  }
}
