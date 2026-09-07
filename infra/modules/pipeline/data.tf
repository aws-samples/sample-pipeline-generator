# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: MIT-0

# Skips are needed also in the data sources for checkov running on terraform plan
data "aws_s3_bucket" "source" {
  count  = local.has_source_bucket ? 1 : 0
  bucket = local.pipeline_buckets["source"]
}

data "aws_s3_bucket" "intermediate" {
  bucket = local.pipeline_buckets["intermediate"]
}

data "aws_s3_bucket" "output" {
  count  = local.has_output_bucket ? 1 : 0
  bucket = local.pipeline_buckets["output"]
}

data "aws_region" "current" {}

data "aws_vpc" "selected" {
  id = var.vpc_id
}

data "aws_prefix_list" "s3" {
  filter {
    name   = "prefix-list-name"
    values = ["com.amazonaws.${data.aws_region.current.region}.s3"]
  }
}

data "aws_caller_identity" "current" {}

data "aws_iam_policy_document" "kms_key" {
  #checkov:skip=CKV_AWS_109: "KMS key policy: root delegation required for key manageability"
  #checkov:skip=CKV_AWS_111: "KMS key policy: resource '*' refers to the key itself, root delegation is AWS-recommended"
  #checkov:skip=CKV_AWS_356: "KMS key policy: resource '*' refers to the key itself, not all resources"
  statement {
    sid    = "Enable IAM User Permissions"
    effect = "Allow"
    principals {
      type        = "AWS"
      identifiers = ["arn:aws:iam::${data.aws_caller_identity.current.account_id}:root"]
    }
    actions   = ["kms:*"]
    resources = ["*"]
  }
}

data "aws_ssm_parameter" "powertools" {
  name = "/aws/service/powertools/python/x86_64/python3.13/latest"
}
