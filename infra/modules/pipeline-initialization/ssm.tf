# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: MIT-0

locals {
  ssm_param_names = { for name in var.ssm_parameters : name => {} }

  create_ssm_kms_key = var.ssm_kms_key_arn == null && length(var.ssm_parameters) > 0

  # Resolve KMS key: use provided ARN or the auto-generated key
  ssm_kms_key_arn = (
    var.ssm_kms_key_arn != null
    ? var.ssm_kms_key_arn
    : local.create_ssm_kms_key ? aws_kms_key.ssm[0].arn : null
  )

  ssm_params_prefix = length(var.ssm_parameters) > 0 ? "/pipelines/${var.pipeline_name}-${var.environment}/params" : null
}

# KMS key policy for the auto-generated SSM key
# Note: In KMS key policies, resources = ["*"] means "this key" — it is
# self-referential and cannot reference the key ARN (circular dependency).
# Reference: https://docs.aws.amazon.com/kms/latest/developerguide/key-policy-overview.html
data "aws_iam_policy_document" "ssm_kms_key" {
  #checkov:skip=CKV_AWS_109: "KMS key policy: resource "*" is self-referential (this key) and principal is account root for IAM delegation"
  #checkov:skip=CKV_AWS_111: "KMS key policy: resource "*" is self-referential (this key) and principal is account root for IAM delegation"
  #checkov:skip=CKV_AWS_356: "KMS key policies require resource "*" which refers to the key itself"
  count = local.create_ssm_kms_key ? 1 : 0

  # Allow account root full management of this key
  statement {
    sid    = "EnableKeyManagement"
    effect = "Allow"
    principals {
      type        = "AWS"
      identifiers = ["arn:aws:iam::${data.aws_caller_identity.current.account_id}:root"]
    }
    actions   = ["kms:*"]
    resources = ["*"]
  }
}

# Auto-generated KMS key when no external key is provided
resource "aws_kms_key" "ssm" {
  count = local.create_ssm_kms_key ? 1 : 0

  description             = "KMS key for SSM parameters – ${var.pipeline_name}-${var.environment}"
  deletion_window_in_days = 10
  enable_key_rotation     = true
  policy                  = data.aws_iam_policy_document.ssm_kms_key[0].json

  tags = local.common_tags
}

resource "aws_kms_alias" "ssm" {
  count = local.create_ssm_kms_key ? 1 : 0

  name          = "alias/${var.pipeline_name}-${var.environment}-ssm"
  target_key_id = aws_kms_key.ssm[0].key_id
}

# Placeholder value overwritten out-of-band; lifecycle ignores future changes.
resource "aws_ssm_parameter" "placeholder" {
  #checkov:skip=CKV_AWS_337: "KMS CMK is always set via local.ssm_kms_key_arn (auto-generated or user-provided)"
  for_each = local.ssm_param_names

  name   = "${local.ssm_params_prefix}/${each.key}"
  type   = "SecureString"
  key_id = local.ssm_kms_key_arn
  # DO NOT MODIFY IN THE CODE
  # MODIFY only on the account after deployment"
  value = "REPLACE_ME"
  tags  = local.common_tags

  lifecycle {
    ignore_changes = [value]
  }
}
