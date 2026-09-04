# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: MIT-0

# ──────────────────────────────────────────────
# Pipeline Account Bootstrap
# ──────────────────────────────────────────────

variable "region" {
  description = "AWS region for all resources"
  type        = string
}

variable "environment" {
  description = "Environment name (e.g. dev, staging, prod)"
  type        = string
  default     = "dev"
}

# Same-account principals already reach the bucket and key through their own IAM
# policies, so the default empty list omits the Allow statements entirely rather
# than granting nothing twice. Populate it to grant cross-account access.
variable "state_backend_principals" {
  description = "IAM principal ARNs granted read/write on the state bucket and use of its KMS key. Empty omits the Allow statements."
  type        = list(string)
  default     = []
}

# ──────────────────────────────────────────────
# VPC — provide existing IDs to skip VPC creation
# ──────────────────────────────────────────────

variable "vpc_id" {
  description = "Existing VPC ID. When set, skips VPC creation and uses this VPC instead."
  type        = string
  default     = null
}

variable "subnet_ids" {
  description = "Existing private subnet IDs. Required when vpc_id is provided."
  type        = list(string)
  default     = []
}

variable "route_table_ids" {
  description = "Existing route table IDs for gateway endpoints. Required when vpc_id is provided."
  type        = list(string)
  default     = []
}

variable "vpc_cidr" {
  description = "CIDR block for the pipeline VPC (only used when vpc_id is not provided)"
  type        = string
  default     = "10.0.0.0/16"
}

variable "vpc_endpoints" {
  description = "List of endpoint types to create. Supported: s3, ecr, dynamodb, stepfunctions, cloudwatch, ssm, secretsmanager"
  type        = list(string)
  default     = ["s3", "ecr", "cloudwatch", "ssm", "secretsmanager"]
}
