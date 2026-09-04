# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: MIT-0

resource "aws_cloudwatch_metric_alarm" "lambda_errors" {
  for_each = var.lambda_functions

  alarm_name          = "${each.value.function_name}-errors"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 3
  metric_name         = "Errors"
  namespace           = "AWS/Lambda"
  period              = 60
  statistic           = "Sum"
  threshold           = each.value.error_threshold
  datapoints_to_alarm = 3
  treat_missing_data  = "notBreaching"

  dimensions = {
    FunctionName = each.value.function_name
  }

  tags = var.tags
}

resource "aws_cloudwatch_metric_alarm" "lambda_throttles" {
  for_each = var.lambda_functions

  alarm_name          = "${each.value.function_name}-throttles"
  comparison_operator = "GreaterThanOrEqualToThreshold"
  evaluation_periods  = 5
  metric_name         = "Throttles"
  namespace           = "AWS/Lambda"
  period              = 60
  statistic           = "Sum"
  threshold           = 1
  datapoints_to_alarm = 5
  treat_missing_data  = "notBreaching"

  dimensions = {
    FunctionName = each.value.function_name
  }

  tags = var.tags
}

resource "aws_cloudwatch_metric_alarm" "lambda_duration" {
  for_each = var.lambda_functions

  alarm_name          = "${each.value.function_name}-duration"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 15
  metric_name         = "Duration"
  namespace           = "AWS/Lambda"
  period              = 60
  extended_statistic  = "p90"
  threshold           = each.value.duration_threshold_ms
  datapoints_to_alarm = 15
  treat_missing_data  = "notBreaching"

  dimensions = {
    FunctionName = each.value.function_name
  }

  tags = var.tags
}

resource "aws_cloudwatch_metric_alarm" "lambda_concurrent_executions" {
  for_each = var.lambda_functions

  alarm_name          = "${each.value.function_name}-concurrent-executions"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 10
  metric_name         = "ConcurrentExecutions"
  namespace           = "AWS/Lambda"
  period              = 60
  statistic           = "Maximum"
  threshold           = var.account_concurrency_quota * each.value.concurrent_exec_percent
  datapoints_to_alarm = 10
  treat_missing_data  = "notBreaching"

  dimensions = {
    FunctionName = each.value.function_name
  }

  tags = var.tags
}
