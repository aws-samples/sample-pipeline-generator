# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: MIT-0

variables {
  vpc_id                 = "vpc-0123456789abcdef0"
  subnet_ids             = ["subnet-0123456789abcdef0", "subnet-0123456789abcdef1"]
  ecr_force_delete       = true
  lambda_steps_code_path = "/tmp/lambda-steps"
}

provider "aws" {
  region = "us-east-1"
}

run "setup" {
  module {
    source = "./iac_tests/setup"
  }

}

run "test_ecr_repository_creation" {
  command = plan

  variables {
    steps = [
      {
        name = "test-step"
        type = "batch"
      },
      {
        name               = "test-step2"
        type               = "batch"
        ecr_repository_url = run.setup.aws_ecr_repo_url
        image_tag          = "v2.0.0"
      }
    ]

    initialization = {
      pipeline_name = "terraform_test"
      environment   = "dev"
      region        = "us-east-1"
      tags          = { Project = "terraform_test" }
      buckets = {
        names   = { intermediate = run.setup.bucket }
        kms_key = run.setup.aws_s3_kms
      }
    }
  }

  assert {
    condition     = aws_ecr_repository.batch_repos["test-step"].name == "terraform_test-dev-test-step"
    error_message = "ECR repository name should match expected format"
  }

  assert {
    condition     = aws_ecr_repository.batch_repos["test-step"].image_tag_mutability == "IMMUTABLE_WITH_EXCLUSION"
    error_message = "ECR repository should have immutable tags with exclusion"
  }

  assert {
    condition     = aws_ecr_repository.batch_repos["test-step"].image_scanning_configuration[0].scan_on_push == true
    error_message = "ECR scan-on-push must be enabled by default"
  }

  assert {
    condition     = length(aws_ecr_repository.batch_repos) == 1
    error_message = "When passing an external repository then only one should be deployed."
  }

  assert {
    condition     = aws_kms_alias.ecr.name == "alias/ecr-terraform_test-dev"
    error_message = "ECR KMS alias should include pipeline_name and environment"
  }

  assert {
    condition     = aws_batch_job_definition.batch_jobs["test-step"].name == "terraform_test-dev-test-step"
    error_message = "Batch job definition name should include pipeline_name and environment"
  }

  assert {
    condition     = aws_cloudwatch_log_group.batch.name == "/aws/batch/terraform_test-dev"
    error_message = "Batch CloudWatch log group should include pipeline_name and environment"
  }

  assert {
    condition     = startswith(aws_security_group.batch_steps.name_prefix, "terraform_test-dev-batch-steps-")
    error_message = "Compute security group name_prefix should include pipeline_name and environment"
  }

  assert {
    condition     = aws_security_group.batch_steps.tags_all["Name"] == "terraform_test-dev-compute-sg"
    error_message = "Compute security group Name tag should include pipeline_name and environment"
  }
}

run "test_optional_source_and_output_buckets" {
  command = plan

  variables {
    steps = [
      {
        name = "process-step"
        type = "batch"
      }
    ]

    initialization = {
      pipeline_name = "terraform_test_all_buckets"
      environment   = "dev"
      region        = "us-east-1"
      tags          = { Project = "terraform_test" }
      buckets = {
        names = {
          source       = run.setup.bucket
          intermediate = run.setup.bucket
          output       = run.setup.bucket
        }
        kms_key = run.setup.aws_s3_kms
      }
    }
  }

  assert {
    condition     = local.has_source_bucket == true
    error_message = "Should detect source bucket when provided"
  }

  assert {
    condition     = local.has_output_bucket == true
    error_message = "Should detect output bucket when provided"
  }

  assert {
    condition     = length(data.aws_s3_bucket.source) == 1
    error_message = "Source bucket data source should be created"
  }

  assert {
    condition     = length(data.aws_s3_bucket.output) == 1
    error_message = "Output bucket data source should be created"
  }
}

run "test_intermediate_only" {
  command = plan

  variables {
    steps = [
      {
        name = "process-step"
        type = "batch"
      }
    ]

    initialization = {
      pipeline_name = "terraform_test_intermediate"
      environment   = "dev"
      region        = "us-east-1"
      tags          = { Project = "terraform_test" }
      buckets = {
        names   = { intermediate = run.setup.bucket }
        kms_key = run.setup.aws_s3_kms
      }
    }
  }

  assert {
    condition     = local.has_source_bucket == false
    error_message = "Should not detect source bucket when not provided"
  }

  assert {
    condition     = local.has_output_bucket == false
    error_message = "Should not detect output bucket when not provided"
  }

  assert {
    condition     = length(data.aws_s3_bucket.source) == 0
    error_message = "Source bucket data source should not be created"
  }

  assert {
    condition     = length(data.aws_s3_bucket.output) == 0
    error_message = "Output bucket data source should not be created"
  }
}

run "test_empty_steps_rejected" {
  command = plan

  variables {
    steps = []

    initialization = {
      pipeline_name = "terraform_test_no_batch"
      environment   = "dev"
      region        = "us-east-1"
      tags          = { Project = "terraform_test" }
      buckets = {
        names   = { intermediate = run.setup.bucket }
        kms_key = run.setup.aws_s3_kms
      }
    }
  }

  expect_failures = [
    var.steps
  ]
}

run "test_pipeline_completion_email_subscriptions" {
  command = plan

  variables {
    steps = [
      {
        name = "process-step"
        type = "batch"
      }
    ]

    initialization = {
      pipeline_name = "terraform_test_completion"
      environment   = "dev"
      region        = "us-east-1"
      tags          = { Project = "terraform_test" }
      buckets = {
        names   = { intermediate = run.setup.bucket }
        kms_key = run.setup.aws_s3_kms
      }
    }

    pipeline_completion_emails = ["user1@example.com", "user2@example.com"]
  }

  assert {
    condition     = length(aws_sns_topic_subscription.pipeline_completion_emails) == 2
    error_message = "Should create one subscription per pipeline completion email"
  }

  assert {
    condition     = aws_sns_topic_subscription.pipeline_completion_emails["user1@example.com"].protocol == "email"
    error_message = "Pipeline completion subscription should use email protocol"
  }

  assert {
    condition     = aws_sns_topic_subscription.pipeline_completion_emails["user1@example.com"].endpoint == "user1@example.com"
    error_message = "Pipeline completion subscription endpoint should match the email"
  }
}

run "test_default_capacity_provider_is_fargate" {
  command = plan

  variables {
    steps = [
      {
        name = "process-step"
        type = "batch"
      }
    ]

    initialization = {
      pipeline_name = "terraform_test_cp"
      environment   = "dev"
      region        = "us-east-1"
      tags          = { Project = "terraform_test" }
      buckets = {
        names   = { intermediate = run.setup.bucket }
        kms_key = run.setup.aws_s3_kms
      }
    }
  }

  assert {
    condition     = aws_batch_compute_environment.pipeline.compute_resources[0].type == "FARGATE"
    error_message = "Default capacity provider should be FARGATE"
  }

  assert {
    condition     = aws_batch_job_definition.batch_jobs["process-step"].platform_capabilities == toset(["FARGATE"])
    error_message = "Default platform capabilities should be FARGATE"
  }
}

run "test_fargate_spot_capacity_provider" {
  command = plan

  variables {
    capacity_provider = "FARGATE_SPOT"

    steps = [
      {
        name = "process-step"
        type = "batch"
      }
    ]

    initialization = {
      pipeline_name = "terraform_test_spot"
      environment   = "dev"
      region        = "us-east-1"
      tags          = { Project = "terraform_test" }
      buckets = {
        names   = { intermediate = run.setup.bucket }
        kms_key = run.setup.aws_s3_kms
      }
    }
  }

  assert {
    condition     = aws_batch_compute_environment.pipeline.compute_resources[0].type == "FARGATE_SPOT"
    error_message = "Capacity provider should be FARGATE_SPOT when configured"
  }

  assert {
    condition     = aws_batch_job_definition.batch_jobs["process-step"].platform_capabilities == toset(["FARGATE"])
    error_message = "Platform capabilities should always be FARGATE regardless of capacity provider"
  }
}

run "test_invalid_capacity_provider_rejected" {
  command = plan

  variables {
    capacity_provider = "EC2"

    steps = [
      {
        name = "process-step"
        type = "batch"
      }
    ]

    initialization = {
      pipeline_name = "terraform_test_invalid_cp"
      environment   = "dev"
      region        = "us-east-1"
      tags          = { Project = "terraform_test" }
      buckets = {
        names   = { intermediate = run.setup.bucket }
        kms_key = run.setup.aws_s3_kms
      }
    }
  }

  expect_failures = [
    var.capacity_provider
  ]
}

run "test_ecr_lifecycle_policy_default" {
  command = plan

  variables {
    steps = [
      {
        name = "test-step"
        type = "batch"
      }
    ]

    initialization = {
      pipeline_name = "terraform_test_ecr_lc"
      environment   = "dev"
      region        = "us-east-1"
      tags          = { Project = "terraform_test" }
      buckets = {
        names   = { intermediate = run.setup.bucket }
        kms_key = run.setup.aws_s3_kms
      }
    }
  }

  assert {
    condition     = length(aws_ecr_lifecycle_policy.batch_repos) == 1
    error_message = "Lifecycle policy should be attached to the managed ECR repository by default"
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

run "test_ecr_lifecycle_policy_minimal" {
  command = plan

  variables {
    ecr_keep_tagged_count     = null
    ecr_expire_untagged_days  = null
    ecr_archive_unpulled_days = null

    steps = [
      {
        name = "test-step"
        type = "batch"
      }
    ]

    initialization = {
      pipeline_name = "terraform_test_ecr_lc_off"
      environment   = "dev"
      region        = "us-east-1"
      tags          = { Project = "terraform_test" }
      buckets = {
        names   = { intermediate = run.setup.bucket }
        kms_key = run.setup.aws_s3_kms
      }
    }
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

run "test_sg_compute_additional_egress_rules" {
  command = plan

  variables {
    steps = [
      {
        name = "process-step"
        type = "batch"
      }
    ]

    initialization = {
      pipeline_name = "terraform_test_sg"
      environment   = "dev"
      region        = "us-east-1"
      tags          = { Project = "terraform_test" }
      buckets = {
        names   = { intermediate = run.setup.bucket }
        kms_key = run.setup.aws_s3_kms
      }
    }

    sg_compute_additional = [
      {
        from_port   = 443
        to_port     = 443
        protocol    = "tcp"
        cidr_blocks = ["10.0.0.0/8"]
      },
      {
        from_port   = 8080
        to_port     = 8080
        protocol    = "tcp"
        cidr_blocks = ["172.16.0.0/12"]
      }
    ]
  }

  assert {
    condition     = length(aws_security_group.batch_steps.egress) == 4
    error_message = "Compute SG should have 4 egress rules (2 default + 2 additional)"
  }
}

run "test_logs_aggregation_resources" {
  command = plan

  variables {
    copy_to_target_ecr_url = "123456789012.dkr.ecr.us-east-1.amazonaws.com/shared-copy"

    steps = [
      {
        name           = "extract"
        type           = "batch"
        copy_to_target = true
      }
    ]

    initialization = {
      pipeline_name = "terraform_test_logs"
      environment   = "dev"
      region        = "us-east-1"
      tags          = { Project = "terraform_test", Pipeline = "terraform_test_logs" }
      buckets = {
        names = {
          intermediate = run.setup.bucket
          output       = run.setup.bucket
        }
        kms_key = run.setup.aws_s3_kms
      }
    }
  }

  # Utility-Lambda log groups are declared explicitly so they carry Pipeline tag
  assert {
    condition     = length(aws_cloudwatch_log_group.pipeline_lambda) == length(local.lambdas)
    error_message = "There must be one aws_cloudwatch_log_group per utility Lambda (so each gets the Pipeline tag)"
  }

  assert {
    condition     = aws_cloudwatch_log_group.pipeline_lambda["parallel_block_initialization"].tags["Pipeline"] == "terraform_test_logs"
    error_message = "Utility Lambda log group must inherit the Pipeline tag from common_tags"
  }

  assert {
    condition     = aws_cloudwatch_log_group.pipeline_lambda["parallel_block_initialization"].name == "/aws/lambda/terraform_test_logs-dev-parallel_block_initialization"
    error_message = "Utility Lambda log-group name must match the function name so the Lambda service reuses it"
  }

  # Step Functions level flipped to ALL so successful runs are also logged
  assert {
    condition     = aws_sfn_state_machine.pipeline.logging_configuration[0].level == "ALL"
    error_message = "Step Functions logging_configuration.level must be ALL (not ERROR) for run-level aggregation"
  }

  # Field indexes on run_id / level for every pipeline log group
  assert {
    condition     = length(aws_cloudwatch_log_index_policy.pipeline) == length(local.pipeline_log_group_names)
    error_message = "Every pipeline log group must have a field-index policy covering run_id and level"
  }

  # Saved Logs Insights queries per pipeline
  assert {
    condition     = aws_cloudwatch_query_definition.all_logs_of_run.name == "Pipelines/terraform_test_logs/dev/All logs of a run"
    error_message = "All logs of a run saved query must be namespaced under Pipelines/<pipeline>/<env>/"
  }

  assert {
    condition     = length(aws_cloudwatch_query_definition.all_logs_of_run.log_group_names) == length(local.pipeline_log_group_names)
    error_message = "All logs of a run must cover every pipeline log group"
  }

  assert {
    condition     = aws_cloudwatch_query_definition.errors_by_run.name == "Pipelines/terraform_test_logs/dev/Errors per run"
    error_message = "Errors per run saved query must exist under the pipeline namespace"
  }

  assert {
    condition     = aws_cloudwatch_query_definition.tail_run.name == "Pipelines/terraform_test_logs/dev/Tail latest events of a run"
    error_message = "Tail run saved query must exist under the pipeline namespace"
  }

  assert {
    condition     = length(aws_cloudwatch_query_definition.step_durations.log_group_names) == 1
    error_message = "Step durations query must target only the SFN log group"
  }

  # Pipeline-wide saved queries (no run_id placeholder) — one per pipeline
  assert {
    condition     = aws_cloudwatch_query_definition.recent_errors.name == "Pipelines/terraform_test_logs/dev/Recent errors (pipeline)"
    error_message = "Recent errors saved query must be namespaced under Pipelines/<pipeline>/<env>/"
  }

  assert {
    condition     = length(aws_cloudwatch_query_definition.recent_errors.log_group_names) == length(local.pipeline_log_group_names)
    error_message = "Recent errors query must cover every pipeline log group"
  }

  assert {
    condition     = !strcontains(aws_cloudwatch_query_definition.recent_errors.query_string, "REPLACE_WITH_RUN_ID")
    error_message = "Recent errors query must not contain a run_id placeholder (pipeline-wide scope)"
  }

  assert {
    condition     = aws_cloudwatch_query_definition.runs_overview.name == "Pipelines/terraform_test_logs/dev/Runs overview"
    error_message = "Runs overview saved query must be namespaced under Pipelines/<pipeline>/<env>/"
  }

  assert {
    condition     = length(aws_cloudwatch_query_definition.runs_overview.log_group_names) == length(local.pipeline_log_group_names)
    error_message = "Runs overview query must cover every pipeline log group"
  }

  assert {
    condition     = !strcontains(aws_cloudwatch_query_definition.runs_overview.query_string, "REPLACE_WITH_RUN_ID")
    error_message = "Runs overview query must not contain a run_id placeholder (pipeline-wide scope)"
  }

  assert {
    condition     = aws_cloudwatch_query_definition.error_rate_by_step.name == "Pipelines/terraform_test_logs/dev/Error rate by step"
    error_message = "Error rate by step saved query must be namespaced under Pipelines/<pipeline>/<env>/"
  }

  assert {
    condition     = length(aws_cloudwatch_query_definition.error_rate_by_step.log_group_names) == length(local.pipeline_log_group_names)
    error_message = "Error rate by step query must cover every pipeline log group"
  }

  assert {
    condition     = aws_cloudwatch_query_definition.run_durations.name == "Pipelines/terraform_test_logs/dev/Run durations (pipeline)"
    error_message = "Run durations saved query must be namespaced under Pipelines/<pipeline>/<env>/"
  }

  assert {
    condition     = length(aws_cloudwatch_query_definition.run_durations.log_group_names) == 1
    error_message = "Run durations query must target only the SFN log group"
  }

  assert {
    condition     = !strcontains(aws_cloudwatch_query_definition.run_durations.query_string, "REPLACE_WITH_RUN_ID")
    error_message = "Run durations query must not contain a run_id placeholder (pipeline-wide scope)"
  }

  # copy_to_target Batch job must set OTEL_SERVICE_NAME + STEP_NAME so records
  # don't log service_undefined. We assert against the local that feeds the
  # container_properties jsonencode because the resource attribute itself is
  # Computed by the AWS provider and unknown at plan time.
  assert {
    condition     = length([for env in local.copy_to_target_environment : env if env.name == "OTEL_SERVICE_NAME"]) == 1
    error_message = "copy_to_target must set OTEL_SERVICE_NAME so records carry a meaningful service name"
  }

  assert {
    condition     = length([for env in local.copy_to_target_environment : env if env.name == "STEP_NAME" && env.value == "copy-to-target"]) == 1
    error_message = "copy_to_target must set STEP_NAME=copy-to-target"
  }
}

run "test_resource_naming_includes_environment" {
  command = plan

  # Unkeyed target mocks every lambda_step_zip instance (OpenTofu rejects instance keys here)
  override_data {
    target = data.archive_file.lambda_step_zip
    values = {
      output_base64sha256 = "dGVzdA=="
    }
  }

  variables {
    steps = [
      {
        name = "batch-step"
        type = "batch"
      },
      {
        name               = "lambda-step-a"
        type               = "lambda"
        lambda_timeout     = 300
        lambda_memory_size = 512
      },
      {
        name           = "collector"
        type           = "batch"
        copy_to_target = true
      }
    ]

    initialization = {
      pipeline_name = "naming_test"
      environment   = "staging"
      region        = "us-east-1"
      tags          = { Project = "terraform_test" }
      buckets = {
        names = {
          source       = run.setup.bucket
          intermediate = run.setup.bucket
          output       = run.setup.bucket
        }
        kms_key = run.setup.aws_s3_kms
      }
    }

    copy_to_target_ecr_url = "123456789012.dkr.ecr.us-east-1.amazonaws.com/copy-to-output"
  }

  # ── ECR ──
  assert {
    condition     = aws_ecr_repository.batch_repos["batch-step"].name == "naming_test-staging-batch-step"
    error_message = "ECR repository name should include pipeline_name and environment"
  }

  assert {
    condition     = aws_kms_alias.ecr.name == "alias/ecr-naming_test-staging"
    error_message = "ECR KMS alias should include pipeline_name and environment"
  }

  # ── Batch job definitions ──
  assert {
    condition     = aws_batch_job_definition.batch_jobs["batch-step"].name == "naming_test-staging-batch-step"
    error_message = "Batch job definition name should include pipeline_name and environment"
  }

  assert {
    condition     = aws_batch_job_definition.copy_to_target[0].name == "naming_test-staging-copy-to-target"
    error_message = "Copy-to-target Batch job definition should include pipeline_name and environment"
  }

  # ── CloudWatch log groups ──
  assert {
    condition     = aws_cloudwatch_log_group.batch.name == "/aws/batch/naming_test-staging"
    error_message = "Batch CloudWatch log group should include pipeline_name and environment"
  }

  # ── Security groups ──
  assert {
    condition     = startswith(aws_security_group.batch_steps.name_prefix, "naming_test-staging-batch-steps-")
    error_message = "Compute security group name_prefix should include pipeline_name and environment"
  }

  assert {
    condition     = aws_security_group.batch_steps.tags_all["Name"] == "naming_test-staging-compute-sg"
    error_message = "Compute security group Name tag should include pipeline_name and environment"
  }

  assert {
    condition     = startswith(aws_security_group.lambda_steps[0].name_prefix, "naming_test-staging-lambda-steps-")
    error_message = "Lambda-steps security group name_prefix should include pipeline_name and environment"
  }

  assert {
    condition     = aws_security_group.lambda_steps[0].tags_all["Name"] == "naming_test-staging-lambda-steps-sg"
    error_message = "Lambda-steps security group Name tag should include pipeline_name and environment"
  }
}
