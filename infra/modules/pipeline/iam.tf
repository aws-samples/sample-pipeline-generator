# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: MIT-0

###############################################################################
# Batch IAM Roles & Policies
###############################################################################

# Batch Execution Role
resource "aws_iam_role" "batch_execution" {
  name               = "${local.pipeline_name}-${local.environment}-batch-execution"
  assume_role_policy = data.aws_iam_policy_document.batch_execution_assume_role.json

  tags = local.common_tags
}

data "aws_iam_policy_document" "batch_execution_assume_role" {
  statement {
    actions = ["sts:AssumeRole"]
    effect  = "Allow"

    principals {
      type        = "Service"
      identifiers = ["ecs-tasks.amazonaws.com"]
    }
  }
}

resource "aws_iam_role_policy_attachment" "batch_execution" {
  role       = aws_iam_role.batch_execution.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy"
}

resource "aws_iam_role_policy" "batch_execution_logs" {
  name = "${local.pipeline_name}-${local.environment}-batch-execution-logs"
  role = aws_iam_role.batch_execution.id

  policy = data.aws_iam_policy_document.batch_execution_logs.json
}

data "aws_iam_policy_document" "batch_execution_logs" {
  statement {
    effect = "Allow"
    actions = [
      "logs:CreateLogStream",
      "logs:PutLogEvents",
    ]
    resources = ["${aws_cloudwatch_log_group.batch.arn}:*"]
  }
}

# Batch Task Role
resource "aws_iam_role" "batch_task" {
  name = "${local.pipeline_name}-${local.environment}-batch-task"

  assume_role_policy = data.aws_iam_policy_document.batch_task_assume_role.json

  tags = local.common_tags
}

data "aws_iam_policy_document" "batch_task_assume_role" {
  statement {
    actions = ["sts:AssumeRole"]
    effect  = "Allow"

    principals {
      type        = "Service"
      identifiers = ["ecs-tasks.amazonaws.com"]
    }
  }
}

resource "aws_iam_role_policy" "batch_task_ssm" {
  count = local.has_ssm_params || length(var.initialization.ssm.external_arns) > 0 ? 1 : 0

  name = "ssm-get-parameters"
  role = aws_iam_role.batch_task.id

  policy = data.aws_iam_policy_document.batch_task_ssm[0].json
}

data "aws_iam_policy_document" "batch_task_ssm" {
  count = local.has_ssm_params || length(var.initialization.ssm.external_arns) > 0 ? 1 : 0

  dynamic "statement" {
    for_each = local.has_ssm_params ? [1] : []
    content {
      effect  = "Allow"
      actions = ["ssm:GetParameter"]
      resources = concat(
        ["arn:aws:ssm:${data.aws_region.current.region}:${data.aws_caller_identity.current.account_id}:parameter${var.initialization.ssm.prefix}/*"],
        var.initialization.ssm.external_arns
      )
    }
  }

  dynamic "statement" {
    for_each = !local.has_ssm_params && length(var.initialization.ssm.external_arns) > 0 ? [1] : []
    content {
      effect    = "Allow"
      actions   = ["ssm:GetParameter"]
      resources = var.initialization.ssm.external_arns
    }
  }

  dynamic "statement" {
    for_each = local.has_ssm_params && local.ssm_kms_key_arn != null ? [1] : []
    content {
      effect    = "Allow"
      actions   = ["kms:Decrypt"]
      resources = [local.ssm_kms_key_arn]
    }
  }

  dynamic "statement" {
    for_each = length(var.initialization.ssm.external_kms_keys) > 0 ? [1] : []
    content {
      effect    = "Allow"
      actions   = ["kms:Decrypt"]
      resources = var.initialization.ssm.external_kms_keys
    }
  }
}

resource "aws_iam_role_policy" "batch_task_secrets" {
  count = local.has_secrets || length(var.initialization.secrets.external_arns) > 0 ? 1 : 0

  name = "secrets-get-secret-value"
  role = aws_iam_role.batch_task.id

  policy = data.aws_iam_policy_document.batch_task_secrets[0].json
}

data "aws_iam_policy_document" "batch_task_secrets" {
  count = local.has_secrets || length(var.initialization.secrets.external_arns) > 0 ? 1 : 0

  dynamic "statement" {
    for_each = local.has_secrets ? [1] : []
    content {
      effect  = "Allow"
      actions = ["secretsmanager:GetSecretValue"]
      resources = concat(
        ["arn:aws:secretsmanager:${data.aws_region.current.region}:${data.aws_caller_identity.current.account_id}:secret:${var.initialization.secrets.prefix}/*"],
        var.initialization.secrets.external_arns
      )
    }
  }

  dynamic "statement" {
    for_each = !local.has_secrets && length(var.initialization.secrets.external_arns) > 0 ? [1] : []
    content {
      effect    = "Allow"
      actions   = ["secretsmanager:GetSecretValue"]
      resources = var.initialization.secrets.external_arns
    }
  }

  dynamic "statement" {
    for_each = local.has_secrets && local.secrets_kms_key_arn != null ? [1] : []
    content {
      effect    = "Allow"
      actions   = ["kms:Decrypt"]
      resources = [local.secrets_kms_key_arn]
    }
  }

  dynamic "statement" {
    for_each = length(var.initialization.secrets.external_kms_keys) > 0 ? [1] : []
    content {
      effect    = "Allow"
      actions   = ["kms:Decrypt"]
      resources = var.initialization.secrets.external_kms_keys
    }
  }
}

resource "aws_iam_role_policy" "batch_s3_access" {
  name = "${local.pipeline_name}-${local.environment}-batch-s3-access"
  role = aws_iam_role.batch_task.id

  policy = data.aws_iam_policy_document.batch_s3_access.json
}

data "aws_iam_policy_document" "batch_s3_access" {
  dynamic "statement" {
    for_each = local.has_source_bucket ? [1] : []
    content {
      effect = "Allow"
      actions = [
        "s3:GetObject",
        "s3:ListBucket",
        "s3:GetObjectTagging",
      ]
      resources = [
        data.aws_s3_bucket.source[0].arn,
        "${data.aws_s3_bucket.source[0].arn}/*",
      ]
    }
  }

  statement {
    effect = "Allow"
    actions = [
      "kms:Decrypt",
      "kms:GenerateDataKey",
    ]
    resources = [local.pipeline_buckets_kms]
  }

  statement {
    effect = "Allow"
    actions = [
      "s3:GetObject",
      "s3:PutObject",
      "s3:ListBucket",
      "s3:GetObjectTagging",
    ]
    resources = concat(
      [
        data.aws_s3_bucket.intermediate.arn,
        "${data.aws_s3_bucket.intermediate.arn}/*",
      ],
      local.has_output_bucket ? [
        data.aws_s3_bucket.output[0].arn,
        "${data.aws_s3_bucket.output[0].arn}/*",
      ] : []
    )
  }
}

###############################################################################
# Lambda Step IAM Roles & Policies
###############################################################################

# Lambda Step Execution Role (shared across all lambda steps)
resource "aws_iam_role" "lambda_step_execution" {
  name = "${local.pipeline_name}-${local.environment}-lambda-step"

  assume_role_policy = data.aws_iam_policy_document.lambda_step_assume_role.json

  tags = local.common_tags
}

data "aws_iam_policy_document" "lambda_step_assume_role" {
  statement {
    actions = ["sts:AssumeRole"]
    effect  = "Allow"

    principals {
      type        = "Service"
      identifiers = ["lambda.amazonaws.com"]
    }
  }
}

resource "aws_iam_role_policy_attachment" "lambda_step_basic" {
  role       = aws_iam_role.lambda_step_execution.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

resource "aws_iam_role_policy_attachment" "lambda_step_xray" {
  role       = aws_iam_role.lambda_step_execution.name
  policy_arn = "arn:aws:iam::aws:policy/CloudWatchLambdaApplicationSignalsExecutionRolePolicy"
}

resource "aws_iam_role_policy_attachment" "lambda_step_vpc" {
  role       = aws_iam_role.lambda_step_execution.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaVPCAccessExecutionRole"
}

resource "aws_iam_role_policy" "lambda_step_dlq" {
  count = length(local.lambda_steps) > 0 ? 1 : 0

  name = "${local.pipeline_name}-${local.environment}-lambda-step-dlq"
  role = aws_iam_role.lambda_step_execution.id

  policy = data.aws_iam_policy_document.lambda_step_dlq[0].json
}

data "aws_iam_policy_document" "lambda_step_dlq" {
  count = length(local.lambda_steps) > 0 ? 1 : 0

  statement {
    effect  = "Allow"
    actions = ["sqs:SendMessage"]
    resources = [
      for step in local.lambda_steps : aws_sqs_queue.lambda_steps_dlq[step.name].arn
    ]
  }

  statement {
    effect = "Allow"
    actions = [
      "kms:Decrypt",
      "kms:GenerateDataKey",
    ]
    resources = [
      "arn:aws:kms:${local.region}:${data.aws_caller_identity.current.account_id}:alias/aws/sqs"
    ]
  }
}

resource "aws_iam_role_policy" "lambda_step_s3_access" {
  name = "${local.pipeline_name}-${local.environment}-lambda-step-s3-access"
  role = aws_iam_role.lambda_step_execution.id

  policy = data.aws_iam_policy_document.lambda_step_s3_access.json
}

# Lambda Step SSM access (mirrors batch_task_ssm)
resource "aws_iam_role_policy" "lambda_step_ssm" {
  count = local.has_ssm_params || length(var.initialization.ssm.external_arns) > 0 ? 1 : 0

  name = "${local.pipeline_name}-${local.environment}-lambda-step-ssm"
  role = aws_iam_role.lambda_step_execution.id

  policy = data.aws_iam_policy_document.lambda_step_ssm[0].json
}

data "aws_iam_policy_document" "lambda_step_ssm" {
  count = local.has_ssm_params || length(var.initialization.ssm.external_arns) > 0 ? 1 : 0

  dynamic "statement" {
    for_each = local.has_ssm_params ? [1] : []
    content {
      effect  = "Allow"
      actions = ["ssm:GetParameter"]
      resources = concat(
        ["arn:aws:ssm:${data.aws_region.current.region}:${data.aws_caller_identity.current.account_id}:parameter${var.initialization.ssm.prefix}/*"],
        var.initialization.ssm.external_arns
      )
    }
  }

  dynamic "statement" {
    for_each = !local.has_ssm_params && length(var.initialization.ssm.external_arns) > 0 ? [1] : []
    content {
      effect    = "Allow"
      actions   = ["ssm:GetParameter"]
      resources = var.initialization.ssm.external_arns
    }
  }

  dynamic "statement" {
    for_each = local.has_ssm_params && local.ssm_kms_key_arn != null ? [1] : []
    content {
      effect    = "Allow"
      actions   = ["kms:Decrypt"]
      resources = [local.ssm_kms_key_arn]
    }
  }

  dynamic "statement" {
    for_each = length(var.initialization.ssm.external_kms_keys) > 0 ? [1] : []
    content {
      effect    = "Allow"
      actions   = ["kms:Decrypt"]
      resources = var.initialization.ssm.external_kms_keys
    }
  }
}

# Lambda Step Secrets Manager access (mirrors step_functions_secrets)
resource "aws_iam_role_policy" "lambda_step_secrets" {
  count = local.has_secrets || length(var.initialization.secrets.external_arns) > 0 ? 1 : 0

  name = "${local.pipeline_name}-${local.environment}-lambda-step-secrets"
  role = aws_iam_role.lambda_step_execution.id

  policy = data.aws_iam_policy_document.lambda_step_secrets[0].json
}

data "aws_iam_policy_document" "lambda_step_secrets" {
  count = local.has_secrets || length(var.initialization.secrets.external_arns) > 0 ? 1 : 0

  dynamic "statement" {
    for_each = local.has_secrets ? [1] : []
    content {
      effect  = "Allow"
      actions = ["secretsmanager:GetSecretValue"]
      resources = concat(
        ["arn:aws:secretsmanager:${data.aws_region.current.region}:${data.aws_caller_identity.current.account_id}:secret:${var.initialization.secrets.prefix}/*"],
        var.initialization.secrets.external_arns
      )
    }
  }

  dynamic "statement" {
    for_each = !local.has_secrets && length(var.initialization.secrets.external_arns) > 0 ? [1] : []
    content {
      effect    = "Allow"
      actions   = ["secretsmanager:GetSecretValue"]
      resources = var.initialization.secrets.external_arns
    }
  }

  dynamic "statement" {
    for_each = local.has_secrets && local.secrets_kms_key_arn != null ? [1] : []
    content {
      effect    = "Allow"
      actions   = ["kms:Decrypt"]
      resources = [local.secrets_kms_key_arn]
    }
  }

  dynamic "statement" {
    for_each = length(var.initialization.secrets.external_kms_keys) > 0 ? [1] : []
    content {
      effect    = "Allow"
      actions   = ["kms:Decrypt"]
      resources = var.initialization.secrets.external_kms_keys
    }
  }
}

data "aws_iam_policy_document" "lambda_step_s3_access" {
  dynamic "statement" {
    for_each = local.has_source_bucket ? [1] : []
    content {
      effect = "Allow"
      actions = [
        "s3:GetObject",
        "s3:ListBucket",
        "s3:GetObjectTagging",
      ]
      resources = [
        data.aws_s3_bucket.source[0].arn,
        "${data.aws_s3_bucket.source[0].arn}/*",
      ]
    }
  }

  statement {
    effect = "Allow"
    actions = [
      "kms:Decrypt",
      "kms:GenerateDataKey",
    ]
    resources = [local.pipeline_buckets_kms]
  }

  statement {
    effect = "Allow"
    actions = [
      "s3:GetObject",
      "s3:PutObject",
      "s3:ListBucket",
      "s3:GetObjectTagging",
    ]
    resources = concat(
      [
        data.aws_s3_bucket.intermediate.arn,
        "${data.aws_s3_bucket.intermediate.arn}/*",
      ],
      local.has_output_bucket ? [
        data.aws_s3_bucket.output[0].arn,
        "${data.aws_s3_bucket.output[0].arn}/*",
      ] : []
    )
  }
}

###############################################################################
# Step Functions IAM Roles & Policies
###############################################################################

# Step Functions Role
resource "aws_iam_role" "step_functions" {
  name = "${local.pipeline_name}-${local.environment}-step-functions"

  assume_role_policy = data.aws_iam_policy_document.step_functions_assume_role.json

  tags = local.common_tags
}

data "aws_iam_policy_document" "step_functions_assume_role" {
  statement {
    actions = ["sts:AssumeRole"]
    effect  = "Allow"

    principals {
      type        = "Service"
      identifiers = ["states.amazonaws.com"]
    }
  }
}

# Step Functions secrets access policy
resource "aws_iam_role_policy" "step_functions_secrets" {
  count = local.has_secrets || length(var.initialization.secrets.external_arns) > 0 ? 1 : 0

  name = "${local.pipeline_name}-${local.environment}-step-functions-secrets"
  role = aws_iam_role.step_functions.id

  policy = data.aws_iam_policy_document.step_functions_secrets[0].json
}

data "aws_iam_policy_document" "step_functions_secrets" {
  count = local.has_secrets || length(var.initialization.secrets.external_arns) > 0 ? 1 : 0

  dynamic "statement" {
    for_each = local.has_secrets ? [1] : []
    content {
      effect  = "Allow"
      actions = ["secretsmanager:GetSecretValue"]
      resources = concat(
        ["arn:aws:secretsmanager:${data.aws_region.current.region}:${data.aws_caller_identity.current.account_id}:secret:${var.initialization.secrets.prefix}/*"],
        var.initialization.secrets.external_arns
      )
    }
  }

  dynamic "statement" {
    for_each = !local.has_secrets && length(var.initialization.secrets.external_arns) > 0 ? [1] : []
    content {
      effect    = "Allow"
      actions   = ["secretsmanager:GetSecretValue"]
      resources = var.initialization.secrets.external_arns
    }
  }

  dynamic "statement" {
    for_each = local.has_secrets && local.secrets_kms_key_arn != null ? [1] : []
    content {
      effect    = "Allow"
      actions   = ["kms:Decrypt"]
      resources = [local.secrets_kms_key_arn]
    }
  }

  dynamic "statement" {
    for_each = length(var.initialization.secrets.external_kms_keys) > 0 ? [1] : []
    content {
      effect    = "Allow"
      actions   = ["kms:Decrypt"]
      resources = var.initialization.secrets.external_kms_keys
    }
  }
}

data "aws_iam_policy_document" "step_functions_batch" {
  statement {
    effect = "Allow"
    actions = [
      "batch:SubmitJob",
      "batch:TerminateJob",
    ]
    resources = [
      "arn:aws:batch:${local.region}:${data.aws_caller_identity.current.account_id}:job-definition/${local.pipeline_name}-*",
      "arn:aws:batch:${local.region}:${data.aws_caller_identity.current.account_id}:job-queue/${local.pipeline_name}-*",
      "arn:aws:batch:${local.region}:${data.aws_caller_identity.current.account_id}:job/*",
    ]
  }

  statement {
    effect = "Allow"
    actions = [
      "batch:DescribeJobs",
    ]
    resources = [
      "arn:aws:batch:${local.region}:${data.aws_caller_identity.current.account_id}:job/*",
    ]
  }

  statement {
    effect = "Allow"
    actions = [
      "events:PutTargets",
      "events:PutRule",
      "events:DescribeRule",
    ]
    resources = [
      "arn:aws:events:${local.region}:${data.aws_caller_identity.current.account_id}:rule/StepFunctions*",
    ]
  }

  statement {
    effect  = "Allow"
    actions = ["lambda:InvokeFunction"]
    resources = concat(
      [
        aws_lambda_function.pipeline_lambda["parallel_block_initialization"].arn
      ],
      [for step in local.lambda_steps : aws_lambda_function.lambda_steps[step.name].arn]
    )
  }

  # X-Ray actions do not support resource-level permissions
  statement {
    effect = "Allow"
    actions = [
      "xray:PutTraceSegments",
      "xray:PutTelemetryRecords",
    ]
    resources = ["*"]
  }

  # Legacy log delivery APIs do not support resource-level permissions
  statement {
    effect = "Allow"
    actions = [
      "logs:CreateLogDelivery",
      "logs:GetLogDelivery",
      "logs:UpdateLogDelivery",
      "logs:DeleteLogDelivery",
      "logs:ListLogDeliveries",
      "logs:PutResourcePolicy",
      "logs:DescribeResourcePolicies",
    ]
    resources = ["*"]
  }

  statement {
    effect    = "Allow"
    actions   = ["logs:DescribeLogGroups"]
    resources = ["arn:aws:logs:${local.region}:${data.aws_caller_identity.current.account_id}:log-group:*"]
  }

  statement {
    effect = "Allow"
    actions = [
      "sns:Publish",
    ]
    resources = [
      "arn:aws:sns:${local.region}:${data.aws_caller_identity.current.account_id}:${local.pipeline_name}-*",
    ]
  }
}

resource "aws_iam_role_policy" "step_functions_batch" {
  name   = "${local.pipeline_name}-${local.environment}-step-functions-batch"
  role   = aws_iam_role.step_functions.id
  policy = data.aws_iam_policy_document.step_functions_batch.json
}
