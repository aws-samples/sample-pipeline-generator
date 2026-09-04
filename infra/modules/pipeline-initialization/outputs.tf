# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: MIT-0

output "s3_kms_key" {
  value       = aws_kms_key.s3_encryption.arn
  description = "S3 KMS encryption key"
}

output "s3_buckets" {
  value = {
    for k, v in aws_s3_bucket.buckets : k => {
      id     = v.id
      arn    = v.arn
      bucket = v.bucket
      region = v.region
    }
  }
  description = "Map of created S3 buckets keyed by bucket suffix (id, arn, bucket, region)"
}

output "config" {
  description = "Configuration object to pass directly to the pipeline module's initialization variable"
  value = {
    pipeline_name = var.pipeline_name
    environment   = var.environment
    region        = var.region
    tags          = local.common_tags

    buckets = {
      names   = { for k, v in aws_s3_bucket.buckets : k => v.bucket }
      kms_key = aws_kms_key.s3_encryption.arn
    }

    cloudwatch = {
      kms_key = aws_kms_key.cloudwatch.arn
    }

    ssm = {
      prefix            = local.ssm_params_prefix
      kms_key           = local.ssm_kms_key_arn
      arns              = { for k, v in aws_ssm_parameter.placeholder : k => v.arn }
      external_arns     = var.ssm_external_parameter_arns
      external_kms_keys = var.ssm_external_kms_key_arns
    }

    secrets = {
      prefix            = local.secrets_prefix
      kms_key           = local.secrets_kms_key_arn
      arns              = { for k, v in aws_secretsmanager_secret.placeholder : k => v.arn }
      external_arns     = var.secrets_external_arns
      external_kms_keys = var.secrets_external_kms_key_arns
    }
  }
}

output "ssm_parameter_arns" {
  description = "ARNs of the SSM parameters created by this module"
  value       = { for k, v in aws_ssm_parameter.placeholder : k => v.arn }
}

output "ssm_kms_key_arn" {
  description = "ARN of the KMS key used for SSM parameter encryption (auto-generated or provided)"
  value       = local.ssm_kms_key_arn
  sensitive   = true
}

output "secrets_arns" {
  description = "ARNs of the Secrets Manager secrets created by this module"
  value       = { for k, v in aws_secretsmanager_secret.placeholder : k => v.arn }
}

output "secrets_kms_key_arn" {
  description = "ARN of the KMS key used for Secrets Manager encryption (auto-generated or provided)"
  value       = local.secrets_kms_key_arn
  sensitive   = true
}

output "cloudwatch_kms_key_arn" {
  description = "ARN of the KMS key used for CloudWatch Logs encryption"
  value       = aws_kms_key.cloudwatch.arn
}
