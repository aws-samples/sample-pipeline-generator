# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: MIT-0

locals {

  common_lambda_env = {
    AWS_LAMBDA_EXEC_WRAPPER = "/opt/otel-instrument",
    PIPELINE_NAME           = "${local.pipeline_name}-${local.environment}"
  }

  lambdas = {
    parallel_block_initialization = {
      description = "Parallel block initialization"
      environment = merge(local.common_lambda_env, {
        "INTERMEDIATE_BUCKET" = data.aws_s3_bucket.intermediate.bucket
        }, local.has_source_bucket ? {
        "SOURCE_BUCKET" = data.aws_s3_bucket.source[0].bucket
      } : {})
    }
  }

  # ADOT Python layer ARNs per region
  # Source: https://aws-otel.github.io/docs/getting-started/lambda
  adot_python_layer_arns = {
    "af-south-1"     = "arn:aws:lambda:af-south-1:904233096616:layer:AWSOpenTelemetryDistroPython:22"
    "ap-east-1"      = "arn:aws:lambda:ap-east-1:888577020596:layer:AWSOpenTelemetryDistroPython:22"
    "ap-east-2"      = "arn:aws:lambda:ap-east-2:412664885777:layer:AWSOpenTelemetryDistroPython:3"
    "ap-northeast-1" = "arn:aws:lambda:ap-northeast-1:615299751070:layer:AWSOpenTelemetryDistroPython:25"
    "ap-northeast-2" = "arn:aws:lambda:ap-northeast-2:615299751070:layer:AWSOpenTelemetryDistroPython:25"
    "ap-northeast-3" = "arn:aws:lambda:ap-northeast-3:615299751070:layer:AWSOpenTelemetryDistroPython:25"
    "ap-south-1"     = "arn:aws:lambda:ap-south-1:615299751070:layer:AWSOpenTelemetryDistroPython:25"
    "ap-south-2"     = "arn:aws:lambda:ap-south-2:796973505492:layer:AWSOpenTelemetryDistroPython:22"
    "ap-southeast-1" = "arn:aws:lambda:ap-southeast-1:615299751070:layer:AWSOpenTelemetryDistroPython:24"
    "ap-southeast-2" = "arn:aws:lambda:ap-southeast-2:615299751070:layer:AWSOpenTelemetryDistroPython:25"
    "ap-southeast-3" = "arn:aws:lambda:ap-southeast-3:039612877180:layer:AWSOpenTelemetryDistroPython:22"
    "ap-southeast-4" = "arn:aws:lambda:ap-southeast-4:713881805771:layer:AWSOpenTelemetryDistroPython:22"
    "ap-southeast-5" = "arn:aws:lambda:ap-southeast-5:152034782359:layer:AWSOpenTelemetryDistroPython:13"
    "ap-southeast-6" = "arn:aws:lambda:ap-southeast-6:313828097273:layer:AWSOpenTelemetryDistroPython:2"
    "ap-southeast-7" = "arn:aws:lambda:ap-southeast-7:980416031188:layer:AWSOpenTelemetryDistroPython:13"
    "ca-central-1"   = "arn:aws:lambda:ca-central-1:615299751070:layer:AWSOpenTelemetryDistroPython:25"
    "ca-west-1"      = "arn:aws:lambda:ca-west-1:595944127152:layer:AWSOpenTelemetryDistroPython:13"
    "cn-north-1"     = "arn:aws-cn:lambda:cn-north-1:440179912924:layer:AWSOpenTelemetryDistroPython:13"
    "cn-northwest-1" = "arn:aws-cn:lambda:cn-northwest-1:440180067931:layer:AWSOpenTelemetryDistroPython:13"
    "eu-central-1"   = "arn:aws:lambda:eu-central-1:615299751070:layer:AWSOpenTelemetryDistroPython:25"
    "eu-central-2"   = "arn:aws:lambda:eu-central-2:156041407956:layer:AWSOpenTelemetryDistroPython:22"
    "eu-north-1"     = "arn:aws:lambda:eu-north-1:615299751070:layer:AWSOpenTelemetryDistroPython:25"
    "eu-south-1"     = "arn:aws:lambda:eu-south-1:257394471194:layer:AWSOpenTelemetryDistroPython:22"
    "eu-south-2"     = "arn:aws:lambda:eu-south-2:490004653786:layer:AWSOpenTelemetryDistroPython:22"
    "eu-west-1"      = "arn:aws:lambda:eu-west-1:615299751070:layer:AWSOpenTelemetryDistroPython:25"
    "eu-west-2"      = "arn:aws:lambda:eu-west-2:615299751070:layer:AWSOpenTelemetryDistroPython:25"
    "eu-west-3"      = "arn:aws:lambda:eu-west-3:615299751070:layer:AWSOpenTelemetryDistroPython:25"
    "il-central-1"   = "arn:aws:lambda:il-central-1:746669239226:layer:AWSOpenTelemetryDistroPython:22"
    "me-central-1"   = "arn:aws:lambda:me-central-1:739275441131:layer:AWSOpenTelemetryDistroPython:21"
    "mx-central-1"   = "arn:aws:lambda:mx-central-1:610118373846:layer:AWSOpenTelemetryDistroPython:13"
    "sa-east-1"      = "arn:aws:lambda:sa-east-1:615299751070:layer:AWSOpenTelemetryDistroPython:25"
    "us-east-1"      = "arn:aws:lambda:us-east-1:615299751070:layer:AWSOpenTelemetryDistroPython:28"
    "us-east-2"      = "arn:aws:lambda:us-east-2:615299751070:layer:AWSOpenTelemetryDistroPython:25"
    "us-west-1"      = "arn:aws:lambda:us-west-1:615299751070:layer:AWSOpenTelemetryDistroPython:32"
    "us-west-2"      = "arn:aws:lambda:us-west-2:615299751070:layer:AWSOpenTelemetryDistroPython:32"
  }

  lambda_layers = [
    data.aws_ssm_parameter.powertools.value,
    local.adot_python_layer_arns[data.aws_region.current.region]
  ]
}

# DLQ for Lambda functions
resource "aws_sqs_queue" "lambda_dlq" {
  for_each                          = local.lambdas
  name                              = "${local.pipeline_name}-${local.environment}-${each.key}-dlq"
  kms_master_key_id                 = "alias/aws/sqs"
  kms_data_key_reuse_period_seconds = 300
  tags                              = local.common_tags
}

# CloudWatch Log Group for utility Lambdas — explicit so the group carries
# local.common_tags instead of being auto-created untagged by the Lambda service.
resource "aws_cloudwatch_log_group" "pipeline_lambda" {
  for_each          = local.lambdas
  name              = "/aws/lambda/${local.pipeline_name}-${local.environment}-${each.key}"
  retention_in_days = var.cw_retention_days
  kms_key_id        = local.cloudwatch_kms_key
  tags              = local.common_tags
}

# Lambda functions
resource "aws_lambda_function" "pipeline_lambda" {
  #checkov:skip=CKV_AWS_45: "Ensure no hard-coded secrets exist in lambda environment"
  #checkov:skip=CKV2_AWS_73: "Ensure AWS SQS uses CMK not AWS default keys for encryption — DLQ uses alias/aws/sqs"
  #checkov:skip=CKV_AWS_115: "Ensure that AWS Lambda function is configured for function-level concurrent execution limit"
  #checkov:skip=CKV_AWS_117: "Ensure that AWS Lambda function is configured inside a VPC"
  for_each         = local.lambdas
  description      = each.value.description
  filename         = data.archive_file.lambda_zip[each.key].output_path
  function_name    = "${local.pipeline_name}-${local.environment}-${each.key}"
  role             = aws_iam_role.lambda_execution[each.key].arn
  handler          = "index.handler"
  source_code_hash = data.archive_file.lambda_zip[each.key].output_base64sha256
  runtime          = "python3.13"
  timeout          = 60

  tracing_config {
    mode = "Active"
  }

  dead_letter_config {
    target_arn = aws_sqs_queue.lambda_dlq[each.key].arn
  }

  dynamic "environment" {
    for_each = [1]
    content {
      variables = merge(each.value.environment, {
        AWS_LAMBDA_EXEC_WRAPPER = "/opt/otel-instrument"
        OTEL_SERVICE_NAME       = "${local.pipeline_name}-${local.environment}-${each.key}"
      })
    }
  }

  layers = local.lambda_layers

  tags = local.common_tags

  # Ensure the pre-created (tagged) log group exists before the function.
  depends_on = [aws_cloudwatch_log_group.pipeline_lambda]
}
data "archive_file" "lambda_zip" {
  for_each    = local.lambdas
  type        = "zip"
  output_path = "${path.module}/${each.key}.zip"
  source {
    content  = file("${path.module}/lambdas/${each.key}/index.py")
    filename = "index.py"
  }
}

# Lambda execution role
resource "aws_iam_role" "lambda_execution" {
  for_each = local.lambdas
  name     = "${local.pipeline_name}-${local.environment}-${each.key}"

  assume_role_policy = data.aws_iam_policy_document.lambda_assume_role.json

  tags = local.common_tags
}

data "aws_iam_policy_document" "lambda_assume_role" {
  statement {
    actions = ["sts:AssumeRole"]
    effect  = "Allow"

    principals {
      type        = "Service"
      identifiers = ["lambda.amazonaws.com"]
    }
  }
}

resource "aws_iam_role_policy_attachment" "lambda_basic" {
  for_each   = local.lambdas
  role       = aws_iam_role.lambda_execution[each.key].name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

resource "aws_iam_role_policy_attachment" "lambda_xray" {
  for_each   = local.lambdas
  role       = aws_iam_role.lambda_execution[each.key].name
  policy_arn = "arn:aws:iam::aws:policy/CloudWatchLambdaApplicationSignalsExecutionRolePolicy"
}

resource "aws_iam_role_policy" "parallel_block_initialization_lambda_s3" {

  name = "${local.pipeline_name}-${local.environment}-parallel-block-initialization"
  role = aws_iam_role.lambda_execution["parallel_block_initialization"].id

  policy = data.aws_iam_policy_document.parallel_block_initialization.json
}

data "aws_iam_policy_document" "parallel_block_initialization" {
  dynamic "statement" {
    for_each = local.has_source_bucket ? [1] : []
    content {
      effect    = "Allow"
      actions   = ["s3:ListBucket"]
      resources = [data.aws_s3_bucket.source[0].arn]
    }
  }

  statement {
    effect    = "Allow"
    actions   = ["s3:ListBucket"]
    resources = [data.aws_s3_bucket.intermediate.arn]
  }

  statement {
    effect    = "Allow"
    actions   = ["sqs:SendMessage"]
    resources = [aws_sqs_queue.lambda_dlq["parallel_block_initialization"].arn]
  }
}
