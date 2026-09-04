# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: MIT-0

locals {
  # Shared context from initialization
  pipeline_name = var.initialization.pipeline_name
  environment   = var.initialization.environment
  region        = var.initialization.region
  # Always tag every resource with Pipeline=<pipeline_name> so saved Logs Insights
  # queries and CloudWatch dashboards can filter by pipeline. User-supplied tags
  # are merged in but cannot override the Pipeline tag.
  common_tags = merge(
    var.initialization.tags,
    var.additional_tags
  )

  # ── Flatten all steps (top-level + inside parallel blocks) by type for resource creation ──
  # Top-level compute steps
  top_batch_steps  = [for step in var.steps : step if step.type == "batch"]
  top_lambda_steps = [for step in var.steps : step if step.type == "lambda"]

  # Parallel block (at most one)
  parallel_block = one([for step in var.steps : step if step.type == "parallel"])
  has_parallel   = local.parallel_block != null

  # Steps inside the parallel block
  parallel_inner_steps        = local.has_parallel ? local.parallel_block.parallel_steps : []
  parallel_inner_batch_steps  = [for step in local.parallel_inner_steps : step if step.type == "batch"]
  parallel_inner_lambda_steps = [for step in local.parallel_inner_steps : step if step.type == "lambda"]

  # All batch/lambda steps (for ECR repo creation, IAM, etc.)
  batch_steps  = concat(local.top_batch_steps, local.parallel_inner_batch_steps)
  lambda_steps = concat(local.top_lambda_steps, local.parallel_inner_lambda_steps)

  # ── Ordered list of all top-level compute/parallel steps (for building previous_steps) ──
  all_top_level_ordered = [for step in var.steps : step if contains(["batch", "lambda", "parallel"], step.type)]

  # ── Step ordering: sequential steps before and after the parallel block ──
  sequential_types = ["batch", "lambda"]
  parallel_idx     = local.has_parallel ? index(var.steps[*].type, "parallel") : -1
  pre_parallel     = local.has_parallel ? [for i, step in var.steps : step if i < local.parallel_idx && contains(local.sequential_types, step.type)] : [for step in var.steps : step if contains(local.sequential_types, step.type)]
  post_parallel    = local.has_parallel ? [for i, step in var.steps : step if i > local.parallel_idx && contains(local.sequential_types, step.type)] : []

  # Resolve initialization config
  pipeline_buckets     = var.initialization.buckets.names
  pipeline_buckets_kms = var.initialization.buckets.kms_key
  cloudwatch_kms_key   = var.initialization.cloudwatch.kms_key

  has_source_bucket = contains(keys(local.pipeline_buckets), "source")
  has_output_bucket = contains(keys(local.pipeline_buckets), "output")
  has_ssm_params    = var.initialization.ssm.prefix != null
  has_secrets       = var.initialization.secrets.prefix != null

  ssm_kms_key_arn     = var.initialization.ssm.kms_key
  secrets_kms_key_arn = var.initialization.secrets.kms_key

  # Steps that should be copied to output
  steps_to_copy = [for step in var.steps : step.name if step.copy_to_target]
  has_copy_step = length(local.steps_to_copy) > 0 && var.copy_to_target_ecr_url != "" && local.has_output_bucket

  # Map of step names to ECR URLs (either provided or created) — batch steps
  ecr_repository_urls = {
    for step in local.batch_steps : step.name => (
      step.ecr_repository_url != null
      ? step.ecr_repository_url
      : aws_ecr_repository.batch_repos[step.name].repository_url
    )
  }
}
