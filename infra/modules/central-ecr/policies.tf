# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: MIT-0

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

  statement {
    sid    = "Allow cross-account decrypt"
    effect = "Allow"
    principals {
      type        = "AWS"
      identifiers = var.allowed_account_ids
    }
    actions = [
      "kms:Decrypt",
      "kms:DescribeKey"
    ]
    resources = ["*"]
  }
}

data "aws_iam_policy_document" "ecr_repository" {

  statement {
    sid    = "AllowCrossAccountServicePull"
    effect = "Allow"
    principals {
      type = "Service"
      identifiers = [
        "ecs-tasks.amazonaws.com",
        "batch.amazonaws.com"
      ]
    }

    actions = [
      "ecr:GetDownloadUrlForLayer",
      "ecr:BatchGetImage",
      "ecr:BatchCheckLayerAvailability"
    ]
    condition {
      test     = "StringEquals"
      variable = "aws:SourceAccount"
      values   = var.allowed_account_ids
    }
  }
}
