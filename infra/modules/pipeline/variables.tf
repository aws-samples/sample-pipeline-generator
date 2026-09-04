# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: MIT-0

variable "initialization" {
  description = "Configuration object from the pipeline-initialization module. Contains shared context (pipeline_name, environment, region, tags), bucket names/KMS key, SSM and Secrets Manager configuration."
  type = object({
    pipeline_name = string
    environment   = string
    region        = string
    tags          = optional(map(string), {})

    buckets = object({
      names   = map(string)
      kms_key = string
    })
    cloudwatch = optional(object({
      kms_key = string
    }), { kms_key = null })
    ssm = optional(object({
      prefix            = optional(string)
      kms_key           = optional(string)
      arns              = optional(map(string), {})
      external_arns     = optional(list(string), [])
      external_kms_keys = optional(list(string), [])
    }), { prefix = null, kms_key = null, arns = {}, external_arns = [], external_kms_keys = [] })
    secrets = optional(object({
      prefix            = optional(string)
      kms_key           = optional(string)
      arns              = optional(map(string), {})
      external_arns     = optional(list(string), [])
      external_kms_keys = optional(list(string), [])
    }), { prefix = null, kms_key = null, arns = {}, external_arns = [], external_kms_keys = [] })
  })

  validation {
    condition     = contains(keys(var.initialization.buckets.names), "intermediate")
    error_message = "The 'intermediate' bucket is mandatory in initialization.buckets.names."
  }
}

# ── Step type for items inside a parallel block ──
variable "steps" {
  description = <<-EOT
    Ordered list of pipeline steps. Steps run sequentially in the order defined.
    One entry may use type="parallel" to define a Map block that fans out over the
    output array of the preceding step.

    Regular step types: "batch", "lambda"
    Special type: "parallel" — contains a nested `parallel_steps` list of compute
    steps that run inside a Step Functions Map state.

    Every compute step automatically stores its result at $.<step_name>_result
    in the state. The parallel block uses `items_path` to reference the array
    from a previous step's result. Inside the Map, each iteration receives the
    array element as the MAP_ITEM env var (lambda payload) or environment
    variable (batch).
  EOT

  type = list(object({
    name = string
    type = string # "batch", "lambda", or "parallel"

    # Batch step configuration
    ram_mb             = optional(number, 2048)
    vcpu               = optional(number, 1)
    image_tag          = optional(string, "latest")
    ecr_repository_url = optional(string, null)
    runtime_parameters = optional(map(string), {})
    copy_to_target     = optional(bool, false)

    # Lambda step configuration
    lambda_timeout           = optional(number, 900)
    lambda_memory_size       = optional(number, 2048)
    lambda_ephemeral_storage = optional(number, 512)
    lambda_layers            = optional(list(string), [])

    # Parallel block configuration (only when type = "parallel")
    input = optional(object({
      type        = string                 # "s3" or "custom"
      from_step   = optional(string, null) # Name of a preceding step whose output provides the fan-out data
      root_prefix = optional(string, null) # S3 prefix for discovery (type=s3 with from_step)
      field       = optional(string, null) # Dot-notation field path in previous step's output (type=custom with from_step)
    }), null)
    parallel_steps = optional(list(object({
      name                     = string
      type                     = string # "batch" or "lambda"
      ram_mb                   = optional(number, 2048)
      vcpu                     = optional(number, 1)
      image_tag                = optional(string, "latest")
      ecr_repository_url       = optional(string, null)
      runtime_parameters       = optional(map(string), {})
      copy_to_target           = optional(bool, false)
      lambda_timeout           = optional(number, 900)
      lambda_memory_size       = optional(number, 2048)
      lambda_ephemeral_storage = optional(number, 512)
      lambda_layers            = optional(list(string), [])
    })), [])
  }))

  validation {
    condition     = length(var.steps) > 0
    error_message = "At least one step must be defined."
  }

  validation {
    condition     = alltrue([for step in var.steps : contains(["lambda", "batch", "parallel"], step.type)])
    error_message = "Only lambda, batch, or parallel steps are allowed."
  }

  # At most one parallel block
  validation {
    condition     = length([for step in var.steps : step if step.type == "parallel"]) <= 1
    error_message = "At most one parallel block is allowed per pipeline."
  }

  # Parallel block must have parallel_steps
  validation {
    condition = alltrue([
      for step in var.steps : length(step.parallel_steps) > 0 if step.type == "parallel"
    ])
    error_message = "A parallel block must contain at least one step in parallel_steps."
  }

  # Parallel block must have input
  validation {
    condition = alltrue([
      for step in var.steps : step.input != null if step.type == "parallel"
    ])
    error_message = "A parallel block must specify an input configuration."
  }

  # input.type must be "s3" or "custom"
  validation {
    condition = alltrue([
      for step in var.steps : contains(["s3", "custom"], step.input.type) if step.type == "parallel" && step.input != null
    ])
    error_message = "Parallel block input.type must be 's3' or 'custom'."
  }

  # input.from_step, when provided, must reference an existing compute step before the parallel block
  validation {
    condition = alltrue([
      for i, step in var.steps :
      step.input.from_step == null || contains(
        [for j, s in var.steps : s.name if j < i && contains(["batch", "lambda"], s.type)],
        step.input.from_step
      )
      if step.type == "parallel" && step.input != null
    ])
    error_message = "input.from_step must reference the name of a compute step (batch or lambda) that appears before the parallel block."
  }

  # custom type with from_step must have field
  validation {
    condition = alltrue([
      for step in var.steps :
      !(step.input.type == "custom" && step.input.from_step != null && step.input.field == null)
      if step.type == "parallel" && step.input != null
    ])
    error_message = "Parallel block with input type 'custom' and from_step must specify a 'field'."
  }

  # Only compute steps inside parallel_steps
  validation {
    condition = alltrue(flatten([
      for step in var.steps : [
        for ps in step.parallel_steps : contains(["batch", "lambda"], ps.type)
      ] if step.type == "parallel"
    ]))
    error_message = "Only batch or lambda steps are allowed inside a parallel block."
  }


}

variable "capacity_provider" {
  description = "Capacity provider for AWS Batch compute environment. Use 'FARGATE' for on-demand or 'FARGATE_SPOT' for cost-optimized spot instances."
  type        = string
  default     = "FARGATE"

  validation {
    condition     = contains(["FARGATE", "FARGATE_SPOT"], var.capacity_provider)
    error_message = "capacity_provider must be either 'FARGATE' or 'FARGATE_SPOT'."
  }
}

variable "max_vcpus" {
  description = "AWS Batch maximum vcpus for across all the running jobs"
  type        = number
  default     = 256

  validation {
    condition     = var.max_vcpus < 257
    error_message = "max_vcpus must be less than 257."
  }
}

variable "vpc_id" {
  description = "VPC ID for Batch compute environment"
  type        = string
}

variable "subnet_ids" {
  description = "Subnet IDs for Batch compute environment"
  type        = list(string)
}

variable "cw_retention_days" {
  description = "Shared value for CloudWatch Logs retention days (validated to be between 15 and 730)"
  type        = number
  default     = 365

  validation {
    condition     = var.cw_retention_days >= 15 && var.cw_retention_days <= 730
    error_message = "cw_retention_days must be between 15 and 730."
  }
}

variable "ecr_force_delete" {
  description = "ECR Delete even if images are present"
  type        = bool
  default     = true
}

variable "ecr_scan_on_push" {
  description = "Enable Amazon ECR basic scanning on image push for batch step repositories."
  type        = bool
  default     = true
}

variable "ecr_keep_tagged_count" {
  description = "Keep the N most recently pushed tagged images (any tag). The image tagged exactly 'latest' is always retained in addition to this. Set to null to disable the rule."
  type        = number
  default     = 3
}

variable "ecr_expire_untagged_days" {
  description = "Expire untagged ECR images after this many days. Set to null to disable the rule."
  type        = number
  default     = 7
}

variable "ecr_archive_unpulled_days" {
  description = "Transition ECR images to archive storage when not pulled for this many days (sinceImagePulled). Images stay retrievable but at lower cost. Set to null to disable."
  type        = number
  default     = 90
}


variable "max_concurrency" {
  description = "Maximum concurrency for the parallel Map step"
  type        = number
  default     = 0
}

variable "copy_to_target_ecr_url" {
  description = "ECR URL for the copy-intermediate-to-output container"
  type        = string
  default     = ""
}

variable "pipeline_completion_emails" {
  description = "List of email addresses to subscribe to the pipeline completion SNS topic"
  type        = list(string)
  default     = []
}


variable "lambda_steps_code_path" {
  description = "Absolute path to the directory containing lambda step subdirectories. Each step expects a folder named after the step (e.g. <path>/<step_name>/main.py). Callers must pass an absolute path using path.module from their root module."
  type        = string
}

variable "sg_compute_additional" {
  description = "Additional egress rules for compute security groups"
  type = list(object({
    from_port   = number
    to_port     = number
    protocol    = string
    cidr_blocks = list(string)
  }))
  default = []
}

variable "additional_tags" {
  description = "Additional Tags"
  type        = map(string)
  default     = {}
}
