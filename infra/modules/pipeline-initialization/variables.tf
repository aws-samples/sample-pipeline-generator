# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: MIT-0

variable "pipeline_name" {
  description = "Name of the pipeline"
  type        = string
}

variable "environment" {
  description = "Environment name (dev, staging, prod)"
  type        = string
  default     = "dev"
}

variable "tags" {
  description = "Tags to apply to all resources"
  type        = map(string)
  default     = {}
}

variable "region" {
  description = "AWS Region"
  type        = string
}

variable "buckets" {
  description = "Set of bucket suffixes to create. Must always include 'intermediate'."
  type        = set(string)
  default     = ["intermediate"]

  validation {
    condition     = alltrue([for b in var.buckets : contains(["source", "intermediate", "output"], b)])
    error_message = "Each bucket must be one of: source, intermediate, output."
  }

  validation {
    condition     = contains(var.buckets, "intermediate")
    error_message = "The 'intermediate' bucket is mandatory."
  }
}

# --- SSM ---

variable "ssm_parameters" {
  description = "SSM parameter names to create as placeholders under /pipelines/<pipeline_name>-<environment>/params/<name>. OpenTofu creates each parameter with a dummy value and ignores future changes, so the real secret is set outside OpenTofu (CLI or console)."
  type        = list(string)
  default     = []
}

variable "ssm_kms_key_arn" {
  description = "ARN of an existing customer managed KMS key for SSM SecureString encryption. When null and ssm_parameters is non-empty, the module creates a dedicated KMS key automatically."
  type        = string
  default     = null
}

# --- Secrets Manager ---

variable "secrets" {
  description = <<-EOT
    Secrets to create as placeholders under /pipelines/<pipeline_name>-<environment>/secrets/<name>.
    OpenTofu creates each secret with a dummy value and ignores future changes.
    Set the real value outside OpenTofu (CLI or console).
  EOT
  type = list(object({
    name = string
  }))
  default = []
}

variable "secrets_kms_key_arn" {
  description = "ARN of an existing customer managed KMS key for Secrets Manager encryption. When null and secrets is non-empty, the module creates a dedicated KMS key automatically."
  type        = string
  default     = null
}

# --- External SSM (grant read access only, resources managed elsewhere) ---

variable "ssm_external_parameter_arns" {
  description = "List of ARNs of externally managed SSM parameters that batch jobs need read access to. The initialization module will not create these parameters — it only passes them through to the pipeline module for IAM grants."
  type        = list(string)
  default     = []
}

variable "ssm_external_kms_key_arns" {
  description = "List of KMS key ARNs used to encrypt the externally managed SSM parameters. Passed through to the pipeline module so it can grant kms:Decrypt to the batch task role."
  type        = list(string)
  default     = []
}

# --- External Secrets Manager (grant read access only, resources managed elsewhere) ---

variable "secrets_external_arns" {
  description = "List of ARNs of externally managed Secrets Manager secrets that batch jobs need read access to. The initialization module will not create these secrets — it only passes them through to the pipeline module for IAM grants."
  type        = list(string)
  default     = []
}

variable "secrets_external_kms_key_arns" {
  description = "List of KMS key ARNs used to encrypt the externally managed secrets. Passed through to the pipeline module so it can grant kms:Decrypt to the batch task role."
  type        = list(string)
  default     = []
}

# --- S3 Intelligent-Tiering ---

variable "s3_lifecycle_rules" {
  description = <<-EOT
    Per-bucket S3 Intelligent-Tiering configuration. Keys must match bucket names
    (source, intermediate, output). Buckets not listed get the default (enabled, no archive tiers).
    - enabled: create a lifecycle rule that transitions objects to INTELLIGENT_TIERING at day 0 (default: true)
    - archive_access_days: opt-in Archive Access tier (min 90, null to disable)
    - deep_archive_access_days: opt-in Deep Archive Access tier (min 180, null to disable)
  EOT
  type = map(object({
    enabled                  = optional(bool, true)
    archive_access_days      = optional(number, null)
    deep_archive_access_days = optional(number, null)
  }))
  default = {}

  validation {
    condition     = alltrue([for k in keys(var.s3_lifecycle_rules) : contains(["source", "intermediate", "output"], k)])
    error_message = "Keys in s3_lifecycle_rules must be one of: source, intermediate, output."
  }
}

variable "s3_force_destroy" {
  description = "Whether to force S3 bucket destroy or not"
  default     = false
  type        = bool
}
