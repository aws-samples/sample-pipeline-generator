# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: MIT-0

output "shared_ecrs" {
  value       = values(aws_ecr_repository.batch_repos)[*].repository_url
  description = "Shared Batch ECR Repositories"
}
