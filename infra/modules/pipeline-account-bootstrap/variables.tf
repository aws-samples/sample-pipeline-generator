# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: MIT-0

variable "tags" {
  description = "Tags applied to module resources. Must include a non-empty 'Owner' key."
  type        = map(string)

  validation {
    condition     = lookup(var.tags, "Owner", "") != ""
    error_message = "tags must include a non-empty 'Owner' key."
  }
}

variable "region" {
  description = "AWS Region for VPC endpoint service names"
  type        = string
}

# ──────────────────────────────────────────────
# VPC Endpoints
# ──────────────────────────────────────────────

variable "vpc_id" {
  description = "ID of the VPC where endpoints will be created. Required when vpc_endpoints is non-empty."
  type        = string
  default     = null
}

variable "vpc_subnet_ids" {
  description = "List of subnet IDs for interface VPC endpoints"
  type        = list(string)
  default     = []
}

variable "vpc_cidr_blocks" {
  description = "CIDR blocks of the VPC, used to scope HTTPS ingress on the interface-endpoint security group. Required when vpc_endpoints requests any interface endpoint."
  type        = list(string)
  default     = []
}

variable "vpc_route_table_ids" {
  description = "List of route table IDs for gateway VPC endpoints (S3, DynamoDB)"
  type        = list(string)
  default     = []
}

variable "vpc_endpoints" {
  description = "List of endpoint types to create. Supported values: s3, ecr, dynamodb, stepfunctions, cloudwatch, ssm, secretsmanager"
  type        = list(string)
  default     = []

  validation {
    condition     = alltrue([for e in var.vpc_endpoints : contains(["s3", "ecr", "dynamodb", "stepfunctions", "cloudwatch", "ssm", "secretsmanager"], e)])
    error_message = "Unsupported endpoint type. Supported values: s3, ecr, dynamodb, stepfunctions, cloudwatch, ssm, secretsmanager."
  }
}
