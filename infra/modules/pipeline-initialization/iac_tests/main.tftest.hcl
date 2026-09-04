# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: MIT-0

run "test_all_buckets_created" {
  command = plan

  variables {
    pipeline_name = "test-pipeline"
    environment   = "dev"
    region        = "us-east-1"
    tags          = { Project = "test" }
    buckets       = ["source", "intermediate", "output"]
  }

  assert {
    condition     = aws_s3_bucket.buckets["source"].bucket == "test-pipeline-dev-source-${data.aws_caller_identity.current.account_id}"
    error_message = "Source S3 bucket name should match expected format"
  }

  assert {
    condition     = aws_s3_bucket.buckets["intermediate"].bucket == "test-pipeline-dev-intermediate-${data.aws_caller_identity.current.account_id}"
    error_message = "Intermediate S3 bucket name should match expected format"
  }

  assert {
    condition     = aws_s3_bucket.buckets["output"].bucket == "test-pipeline-dev-output-${data.aws_caller_identity.current.account_id}"
    error_message = "Output S3 bucket name should match expected format"
  }
}

run "test_intermediate_only" {
  command = plan

  variables {
    pipeline_name = "test-pipeline"
    environment   = "dev"
    region        = "us-east-1"
    tags          = {}
    buckets       = ["intermediate"]
  }

  assert {
    condition     = length(aws_s3_bucket.buckets) == 1
    error_message = "Only one bucket should be created when only intermediate is specified"
  }

  assert {
    condition     = aws_s3_bucket.buckets["intermediate"].bucket == "test-pipeline-dev-intermediate-${data.aws_caller_identity.current.account_id}"
    error_message = "Intermediate bucket should always be created"
  }
}

run "test_s3_bucket_security" {
  command = plan

  variables {
    pipeline_name = "test-pipeline"
    environment   = "dev"
    region        = "us-east-1"
    tags          = {}
    buckets       = ["source", "intermediate", "output"]
  }

  assert {
    condition     = aws_s3_bucket_public_access_block.buckets["source"].block_public_acls == true
    error_message = "Source bucket should block public ACLs"
  }

  assert {
    condition     = aws_s3_bucket_public_access_block.buckets["intermediate"].block_public_acls == true
    error_message = "Intermediate bucket should block public ACLs"
  }

  assert {
    condition     = aws_s3_bucket_public_access_block.buckets["output"].block_public_acls == true
    error_message = "Output bucket should block public ACLs"
  }

  assert {
    condition     = aws_s3_bucket_versioning.buckets["intermediate"].versioning_configuration[0].status == "Enabled"
    error_message = "Intermediate bucket should have versioning enabled"
  }
}

run "test_ssm_parameters_created" {
  command = plan

  variables {
    pipeline_name  = "test-pipeline"
    environment    = "dev"
    region         = "us-east-1"
    tags           = {}
    buckets        = ["intermediate"]
    ssm_parameters = ["api_key", "log_level"]
  }

  assert {
    condition     = aws_ssm_parameter.placeholder["api_key"].name == "/pipelines/test-pipeline-dev/params/api_key"
    error_message = "SSM parameter name should match expected format"
  }

  assert {
    condition     = aws_ssm_parameter.placeholder["log_level"].name == "/pipelines/test-pipeline-dev/params/log_level"
    error_message = "SSM parameter name should match expected format"
  }

  assert {
    condition     = aws_ssm_parameter.placeholder["api_key"].type == "SecureString"
    error_message = "SSM parameters should be SecureString type"
  }

  assert {
    condition     = length(aws_kms_key.ssm) == 1
    error_message = "A KMS key should be auto-generated when no external key is provided"
  }
}

run "test_secret_created" {
  command = plan

  variables {
    pipeline_name = "test-pipeline"
    environment   = "dev"
    region        = "us-east-1"
    tags          = {}
    buckets       = ["intermediate"]
    secrets       = [{ name = "db_password" }]
  }

  assert {
    condition     = aws_secretsmanager_secret.placeholder["db_password"].name == "/pipelines/test-pipeline-dev/secrets/db_password"
    error_message = "Secret name should match expected format"
  }

  assert {
    condition     = length(aws_kms_key.secrets) == 1
    error_message = "A KMS key should be auto-generated when no external key is provided"
  }
}

run "test_no_ssm_or_secrets_by_default" {
  command = plan

  variables {
    pipeline_name = "test-pipeline"
    environment   = "dev"
    region        = "us-east-1"
    tags          = {}
    buckets       = ["intermediate"]
  }

  assert {
    condition     = length(aws_ssm_parameter.placeholder) == 0
    error_message = "No SSM parameters should be created by default"
  }

  assert {
    condition     = length(aws_secretsmanager_secret.placeholder) == 0
    error_message = "No secrets should be created by default"
  }

  assert {
    condition     = length(aws_kms_key.ssm) == 0
    error_message = "No SSM KMS key should be created when no parameters are defined"
  }

  assert {
    condition     = length(aws_kms_key.secrets) == 0
    error_message = "No secrets KMS key should be created when no secrets are defined"
  }
}

run "test_intelligent_tiering_enabled_by_default" {
  command = plan

  variables {
    pipeline_name = "test-pipeline"
    environment   = "dev"
    region        = "us-east-1"
    buckets       = ["source", "intermediate", "output"]
  }

  assert {
    condition     = length(aws_s3_bucket_lifecycle_configuration.buckets) == 3
    error_message = "A lifecycle rule transitioning to INTELLIGENT_TIERING should be created for every bucket by default"
  }

  assert {
    condition     = contains(flatten([for r in aws_s3_bucket_lifecycle_configuration.buckets["intermediate"].rule : [for t in r.transition : t.storage_class]]), "INTELLIGENT_TIERING")
    error_message = "The lifecycle rule must transition objects to the INTELLIGENT_TIERING storage class"
  }

  assert {
    condition     = length(aws_s3_bucket_intelligent_tiering_configuration.buckets) == 0
    error_message = "No archive Intelligent-Tiering config should be created unless archive tiers are set"
  }
}

run "test_intelligent_tiering_disabled_per_bucket" {
  command = plan

  variables {
    pipeline_name = "test-pipeline"
    environment   = "dev"
    region        = "us-east-1"
    buckets       = ["source", "intermediate"]
    s3_lifecycle_rules = {
      source = { enabled = false }
    }
  }

  assert {
    condition     = length(aws_s3_bucket_lifecycle_configuration.buckets) == 1
    error_message = "Only the intermediate bucket should have the IT lifecycle rule; source is explicitly disabled"
  }

  assert {
    condition     = contains(keys(aws_s3_bucket_lifecycle_configuration.buckets), "intermediate")
    error_message = "The intermediate bucket should still have the IT lifecycle rule"
  }
}

run "test_intelligent_tiering_archive_per_bucket" {
  command = plan

  variables {
    pipeline_name = "test-pipeline"
    environment   = "dev"
    region        = "us-east-1"
    buckets       = ["source", "intermediate", "output"]
    s3_lifecycle_rules = {
      source = { archive_access_days = 90 }
      output = { archive_access_days = 90, deep_archive_access_days = 180 }
    }
  }

  assert {
    condition     = length(aws_s3_bucket_intelligent_tiering_configuration.buckets) == 2
    error_message = "Archive IT config should be created only for buckets that opt in to archive tiers"
  }

  assert {
    condition     = aws_s3_bucket_intelligent_tiering_configuration.buckets["source"].name == "EntireBucket"
    error_message = "Intelligent-Tiering configuration name should be EntireBucket"
  }

  assert {
    condition     = length(aws_s3_bucket_intelligent_tiering_configuration.buckets["source"].tiering) == 1
    error_message = "Source bucket should have only the Archive Access tier configured"
  }

  assert {
    condition     = length(aws_s3_bucket_intelligent_tiering_configuration.buckets["output"].tiering) == 2
    error_message = "Output bucket should have both Archive and Deep Archive tiers configured"
  }
}

run "test_invalid_lifecycle_rule_key_rejected" {
  command = plan

  variables {
    pipeline_name = "test-pipeline"
    environment   = "dev"
    region        = "us-east-1"
    buckets       = ["intermediate"]
    s3_lifecycle_rules = {
      unknown = { archive_access_days = 90 }
    }
  }

  expect_failures = [
    var.s3_lifecycle_rules
  ]
}
