# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: MIT-0

output "pipeline_name" {
  description = "Name of the pipeline"
  value       = local.pipeline_name
}

output "step_function_arn" {
  description = "ARN of the Step Functions state machine"
  value       = aws_sfn_state_machine.pipeline.arn
}

output "ecr_repositories" {
  description = "ECR repository URLs for batch steps (only module-managed repos)"
  value = {
    for step_name, repo in aws_ecr_repository.batch_repos : step_name => {
      url = repo.repository_url
      arn = repo.arn
    }
  }
}

output "batch_job_queue_arn" {
  description = "ARN of the Batch job queue"
  value       = aws_batch_job_queue.pipeline.arn
}

output "batch_job_definitions" {
  description = "ARNs of Batch job definitions"
  value = {
    for step_name, job_def in aws_batch_job_definition.batch_jobs : step_name => job_def.arn
  }
}

output "pipeline_completion_topic_arn" {
  description = "ARN of the pipeline completion SNS topic"
  value       = aws_sns_topic.pipeline_completion.arn
}

output "parallel_block_initialization_function_name" {
  description = "Name of the parallel block initialization Lambda function"
  value       = aws_lambda_function.pipeline_lambda["parallel_block_initialization"].function_name
}

output "lambda_function_names" {
  description = "Map of Lambda function names"
  value = {
    for key, lambda in aws_lambda_function.pipeline_lambda : key => lambda.function_name
  }
}

output "lambda_step_function_arns" {
  description = "ARNs of Lambda functions for lambda-type pipeline steps"
  value = {
    for step_name, fn in aws_lambda_function.lambda_steps : step_name => fn.arn
  }
}
