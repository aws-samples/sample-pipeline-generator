# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: MIT-0

data "aws_region" "current" {}

locals {
  # Load full pipeline definition from YAML (schema-validated by editor)
  pipeline_config = yamldecode(file("../${path.module}/pipeline.yaml"))

  # Pipeline metadata from YAML
  pipeline_name              = local.pipeline_config.pipeline_name
  tags                       = try(local.pipeline_config.tags, {})
  buckets                    = try(local.pipeline_config.buckets, ["intermediate"])
  pipeline_completion_emails = try(local.pipeline_config.pipeline_completion_emails, [])
  max_concurrency            = try(local.pipeline_config.max_concurrency, 0)
  cw_retention_days          = try(local.pipeline_config.cw_retention_days, 365)
  capacity_provider          = try(local.pipeline_config.capacity_provider, "FARGATE")
  ssm_parameters             = try(local.pipeline_config.ssm_parameters, [])
  secrets                    = try(local.pipeline_config.secrets, [])

  # Steps from YAML
  steps = local.pipeline_config.steps
}

module "pipeline_init" {
  # These are false positive, checkov is not able to understand these rules when set as lists and from remote modules.
  #checkov:skip=CKV_AWS_145: "Ensure that S3 buckets are encrypted with KMS by default"
  source = "../../../infra/modules/pipeline-initialization"

  pipeline_name = local.pipeline_name
  environment   = var.environment
  region        = data.aws_region.current.region
  buckets       = local.buckets

  ssm_parameters = local.ssm_parameters
  secrets        = local.secrets

  tags = local.tags
}

# This is deployed during the account setup and first push of the repository
data "aws_ssm_parameter" "copy_to_output_shared_ecr_repo_url" {
  name = "/pipelines/shared-copy-intermediate-to-output-ecr-url"
}

module "pipeline" {
  depends_on = [module.pipeline_init]
  source     = "../../../infra/modules/pipeline"

  vpc_id     = var.vpc_id
  subnet_ids = var.subnet_ids

  initialization = module.pipeline_init.config

  capacity_provider = local.capacity_provider

  copy_to_target_ecr_url = data.aws_ssm_parameter.copy_to_output_shared_ecr_repo_url.value
  ecr_force_delete       = var.ecr_force_delete
  max_concurrency        = local.max_concurrency
  cw_retention_days      = local.cw_retention_days

  steps = local.steps

  lambda_steps_code_path = "${path.module}/../code"

  pipeline_completion_emails = local.pipeline_completion_emails
  sg_compute_additional      = var.sg_compute_additional
}

module "lambda_alarms" {
  source = "../../../infra/modules/lambda-alarms"

  lambda_functions = {
    for key, function_name in module.pipeline.lambda_function_names : key => {
      function_name           = function_name
      error_threshold         = 5
      duration_threshold_ms   = 50000
      concurrent_exec_percent = 0.9
    }
  }

  tags = local.tags
}
