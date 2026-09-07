# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: MIT-0

# Pipeline completion SNS topic
resource "aws_sns_topic" "pipeline_completion" {
  name              = "${local.pipeline_name}-${local.environment}-completion"
  kms_master_key_id = "alias/aws/sns"
  tags              = local.common_tags
}

resource "aws_sns_topic_subscription" "pipeline_completion_emails" {
  for_each = toset(var.pipeline_completion_emails)

  topic_arn = aws_sns_topic.pipeline_completion.arn
  protocol  = "email"
  endpoint  = each.value
}
