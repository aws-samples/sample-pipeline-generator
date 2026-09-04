# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: MIT-0

# Code-based Lambda functions for "lambda" type pipeline steps.
# Each step's code lives in code/<step-name>/main.py and is packaged as a zip.
# Users can attach Lambda layers (e.g. for shared libraries / dependencies).
# Lambda steps run inside the pipeline VPC for secure access to S3 and other services.

# DLQ for Lambda step functions
resource "aws_sqs_queue" "lambda_steps_dlq" {
  for_each = { for step in local.lambda_steps : step.name => step }

  name                              = "${local.pipeline_name}-${local.environment}-step-${each.key}-dlq"
  kms_master_key_id                 = "alias/aws/sqs"
  kms_data_key_reuse_period_seconds = 300
  tags                              = local.common_tags
}

# CloudWatch Log Group for Lambda step functions
resource "aws_cloudwatch_log_group" "lambda_steps" {
  for_each = { for step in local.lambda_steps : step.name => step }

  name              = "/aws/lambda/${local.pipeline_name}-${local.environment}-step-${each.key}"
  retention_in_days = var.cw_retention_days
  kms_key_id        = local.cloudwatch_kms_key
  tags              = local.common_tags
}

# Package step code from code/<step-name>/ into a zip
data "archive_file" "lambda_step_zip" {
  for_each = { for step in local.lambda_steps : step.name => step }

  type        = "zip"
  output_path = "${path.module}/lambda-step-${each.key}.zip"
  source_dir  = "${var.lambda_steps_code_path}/${each.key}"
}

# Lambda functions for pipeline steps (code/zip based)
resource "aws_lambda_function" "lambda_steps" {
  #checkov:skip=CKV_AWS_45: "Ensure no hard-coded secrets exist in lambda environment"
  for_each = { for step in local.lambda_steps : step.name => step }

  function_name    = "${local.pipeline_name}-${local.environment}-step-${each.key}"
  description      = "Pipeline step: ${each.key}"
  role             = aws_iam_role.lambda_step_execution.arn
  package_type     = "Zip"
  filename         = data.archive_file.lambda_step_zip[each.key].output_path
  source_code_hash = data.archive_file.lambda_step_zip[each.key].output_base64sha256
  handler          = "main.handler"
  runtime          = "python3.13"
  timeout          = each.value.lambda_timeout
  memory_size      = each.value.lambda_memory_size

  ephemeral_storage {
    size = each.value.lambda_ephemeral_storage
  }

  vpc_config {
    subnet_ids         = var.subnet_ids
    security_group_ids = [aws_security_group.lambda_steps[0].id]
  }

  tracing_config {
    mode = "Active"
  }

  dead_letter_config {
    target_arn = aws_sqs_queue.lambda_steps_dlq[each.key].arn
  }

  environment {
    variables = merge(
      local.has_source_bucket ? {
        SOURCE_BUCKET = data.aws_s3_bucket.source[0].bucket
      } : {},
      {
        INTERMEDIATE_BUCKET = data.aws_s3_bucket.intermediate.bucket
      },
      local.has_output_bucket ? {
        OUTPUT_BUCKET = data.aws_s3_bucket.output[0].bucket
      } : {},
      local.has_ssm_params ? {
        SSM_PARAMS_PREFIX = var.initialization.ssm.prefix
      } : {},
      local.has_secrets ? {
        SECRETS_PREFIX = var.initialization.secrets.prefix
      } : {},
      {
        STEP_NAME               = each.key
        AWS_LAMBDA_EXEC_WRAPPER = "/opt/otel-instrument"
        OTEL_SERVICE_NAME       = "${local.pipeline_name}-${local.environment}-step-${each.key}"
        PIPELINE_NAME           = "${local.pipeline_name}-${local.environment}"
      },
      each.value.runtime_parameters
    )
  }

  layers = concat(
    local.lambda_layers,
    each.value.lambda_layers
  )

  tags = local.common_tags

  depends_on = [aws_cloudwatch_log_group.lambda_steps]
}
