# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: MIT-0

output "bucket" {
  value       = aws_s3_bucket.bucket.bucket
  description = "Helper bucket"
}

output "account_id" {
  value       = data.aws_caller_identity.current.account_id
  description = "Current account_id"
}

output "aws_s3_kms" {
  description = "AWS managed S3 KMS Key"
  value       = data.aws_kms_key.s3.arn
}

output "aws_ecr_repo_url" {
  description = "Test ECR ARN"
  value       = aws_ecr_repository.batch_repos.repository_url
}
