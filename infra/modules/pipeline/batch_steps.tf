# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: MIT-0

# Batch Compute Environment

resource "aws_batch_compute_environment" "pipeline" {
  name  = "${local.pipeline_name}-${local.environment}-${lower(replace(var.capacity_provider, "_", "-"))}"
  type  = "MANAGED"
  state = "ENABLED"

  compute_resources {
    type               = var.capacity_provider
    max_vcpus          = var.max_vcpus
    security_group_ids = [aws_security_group.batch_steps.id]
    subnets            = var.subnet_ids
  }

  tags = merge(
    { Name = "${local.pipeline_name}-${local.environment}" },
    local.common_tags
  )

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_batch_job_queue" "pipeline" {
  name     = "${local.pipeline_name}-${local.environment}"
  state    = "ENABLED"
  priority = 1

  compute_environment_order {
    order               = 1
    compute_environment = aws_batch_compute_environment.pipeline.arn
  }

  tags = local.common_tags
}

# Batch Job Definitions
resource "aws_batch_job_definition" "batch_jobs" {
  for_each = { for step in local.batch_steps : step.name => step }

  name = "${local.pipeline_name}-${local.environment}-${each.key}"
  type = "container"

  platform_capabilities = ["FARGATE"]

  # Please check
  # https://docs.aws.amazon.com/batch/latest/userguide/bestpractice6.html
  # Host EC2* — can be: Spot reclamation / instance terminated
  # AGENT — can be: ECS agent lost contact
  # on_reason and on_status_reason are glob patterns, not fixed enums.
  retry_strategy {
    attempts = 3

    evaluate_on_exit {
      on_status_reason = "Host EC2*"
      action           = "RETRY"
    }
    evaluate_on_exit {
      on_reason = "AGENT"
      action    = "RETRY"
    }
    evaluate_on_exit {
      on_reason = "*"
      action    = "EXIT"
    }
  }

  container_properties = jsonencode({
    image = "${local.ecr_repository_urls[each.key]}:${lookup(each.value, "image_tag", "latest")}"

    fargatePlatformConfiguration = {
      platformVersion = "LATEST"
    }
    ephemeralStorage = {
      sizeInGiB = 100
    }

    readonlyRootFilesystem = true

    resourceRequirements = [
      {
        type  = "VCPU"
        value = tostring(each.value.vcpu)
      },
      {
        type  = "MEMORY"
        value = tostring(each.value.ram_mb)
      }
    ]

    executionRoleArn = aws_iam_role.batch_execution.arn
    jobRoleArn       = aws_iam_role.batch_task.arn

    logConfiguration = {
      logDriver = "awslogs"
      options = {
        "awslogs-group"         = aws_cloudwatch_log_group.batch.name
        "awslogs-region"        = data.aws_region.current.region
        "awslogs-stream-prefix" = each.key
      }
    }

    environment = concat(
      local.has_source_bucket ? [
        {
          name  = "SOURCE_BUCKET"
          value = data.aws_s3_bucket.source[0].bucket
        }
      ] : [],
      [
        {
          name  = "INTERMEDIATE_BUCKET"
          value = data.aws_s3_bucket.intermediate.bucket
        }
      ],
      [
        {
          name  = "STEP_NAME"
          value = each.key
        }
      ],
      local.has_ssm_params ? [
        {
          name  = "SSM_PARAMS_PREFIX"
          value = var.initialization.ssm.prefix
        }
      ] : [],
      local.has_secrets ? [
        {
          name  = "SECRETS_PREFIX"
          value = var.initialization.secrets.prefix
        }
      ] : [],
      local.has_output_bucket ? [
        {
          name  = "OUTPUT_BUCKET"
          value = data.aws_s3_bucket.output[0].bucket
        }
      ] : [],
      [
        for key, value in each.value.runtime_parameters : {
          name  = key
          value = value
        }
      ],
      [
        {
          name  = "PIPELINE_NAME"
          value = "${local.pipeline_name}-${local.environment}"
        }
      ]
    )
  })

  tags = local.common_tags
}

# Environment variables injected into the copy_to_target Batch container.
# Kept as a top-level local (instead of inlined in the jsonencode below) so
# that it stays evaluable at `terraform plan` time — the resource's
# `container_properties` attribute is declared Computed by the AWS provider
# and also references IAM-role ARNs that are known-after-apply, which makes
# `jsondecode(aws_batch_job_definition.copy_to_target[0].container_properties)`
# unusable in unit tests. Asserting against this local sidesteps both issues.
locals {
  copy_to_target_environment = local.has_copy_step ? [
    {
      name  = "INTERMEDIATE_BUCKET"
      value = data.aws_s3_bucket.intermediate.bucket
    },
    {
      name  = "OUTPUT_BUCKET"
      value = data.aws_s3_bucket.output[0].bucket
    },
    {
      name  = "STEP_NAME"
      value = "copy-to-target"
    },
    {
      name  = "OTEL_SERVICE_NAME"
      value = "${local.pipeline_name}-${local.environment}-copy-to-target"
    }
  ] : []
}

# Batch Job Definition for Copy to Output
resource "aws_batch_job_definition" "copy_to_target" {
  count = local.has_copy_step ? 1 : 0

  name = "${local.pipeline_name}-${local.environment}-copy-to-target"
  type = "container"

  platform_capabilities = ["FARGATE"]

  retry_strategy {
    attempts = 3

    evaluate_on_exit {
      on_status_reason = "Host EC2*"
      action           = "RETRY"
    }
    evaluate_on_exit {
      on_reason = "AGENT"
      action    = "RETRY"
    }
    evaluate_on_exit {
      on_reason = "*"
      action    = "EXIT"
    }
  }

  container_properties = jsonencode({
    image = "${var.copy_to_target_ecr_url}:latest"

    fargatePlatformConfiguration = {
      platformVersion = "LATEST"
    }
    ephemeralStorage = {
      sizeInGiB = 100
    }

    readonlyRootFilesystem = true

    resourceRequirements = [
      {
        type  = "VCPU"
        value = "1"
      },
      {
        type  = "MEMORY"
        value = "2048"
      }
    ]

    executionRoleArn = aws_iam_role.batch_execution.arn
    jobRoleArn       = aws_iam_role.batch_task.arn

    logConfiguration = {
      logDriver = "awslogs"
      options = {
        "awslogs-group"         = aws_cloudwatch_log_group.batch.name
        "awslogs-region"        = data.aws_region.current.region
        "awslogs-stream-prefix" = "copy-to-target"
      }
    }

    environment = local.copy_to_target_environment
  })

  tags = local.common_tags
}
