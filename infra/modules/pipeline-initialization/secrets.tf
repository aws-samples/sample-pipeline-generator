# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: MIT-0

locals {
  secrets_map = { for s in var.secrets : s.name => s }

  create_secrets_kms_key = var.secrets_kms_key_arn == null && length(var.secrets) > 0

  # Resolve KMS key: use provided ARN or the auto-generated key
  secrets_kms_key_arn = (
    var.secrets_kms_key_arn != null
    ? var.secrets_kms_key_arn
    : local.create_secrets_kms_key ? aws_kms_key.secrets[0].arn : null
  )

  secrets_prefix = length(var.secrets) > 0 ? "/pipelines/${var.pipeline_name}-${var.environment}/secrets" : null
}

# KMS key policy for the auto-generated Secrets Manager key
# Note: In KMS key policies, resources = ["*"] means "this key" — it is
# self-referential and cannot reference the key ARN (circular dependency).
# Reference: https://docs.aws.amazon.com/kms/latest/developerguide/key-policy-overview.html
data "aws_iam_policy_document" "secrets_kms_key" {
  #checkov:skip=CKV_AWS_109: "KMS key policy: resource "*" is self-referential (this key) and principal is account root for IAM delegation"
  #checkov:skip=CKV_AWS_111: "KMS key policy: resource "*" is self-referential (this key) and principal is account root for IAM delegation"
  #checkov:skip=CKV_AWS_356: "KMS key policies require resource "*" which refers to the key itself"
  count = local.create_secrets_kms_key ? 1 : 0

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
resource "aws_kms_key" "secrets" {
  count = local.create_secrets_kms_key ? 1 : 0

  description             = "KMS key for Secrets Manager - ${var.pipeline_name}-${var.environment}"
  deletion_window_in_days = 10
  enable_key_rotation     = true
  policy                  = data.aws_iam_policy_document.secrets_kms_key[0].json

  tags = local.common_tags
}

resource "aws_kms_alias" "secrets" {
  count = local.create_secrets_kms_key ? 1 : 0

  name          = "alias/${var.pipeline_name}-${var.environment}-secrets"
  target_key_id = aws_kms_key.secrets[0].key_id
}

# Placeholder secrets — set the real value outside OpenTofu (CLI / console)
resource "aws_secretsmanager_secret" "placeholder" {
  #checkov:skip=CKV2_AWS_57: "Ensure Secrets Manager should have automatic rotation enabled"
  #checkov:skip=CKV_AWS_149: "KMS CMK is always set via local.secrets_kms_key_arn (auto-generated or user-provided)"
  for_each = local.secrets_map

  name       = "${local.secrets_prefix}/${each.key}"
  kms_key_id = local.secrets_kms_key_arn

  tags = local.common_tags
}

resource "aws_secretsmanager_secret_version" "placeholder" {
  for_each = local.secrets_map

  secret_id = aws_secretsmanager_secret.placeholder[each.key].id
  # DO NOT MODIFY IN THE CODE
  # MODIFY only on the account after deployment"
  secret_string = "REPLACE_ME"

  lifecycle {
    ignore_changes = [secret_string]
  }
}
