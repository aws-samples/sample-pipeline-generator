# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: MIT-0

variable "region" {
  description = "AWS region for all resources"
  type        = string
}

variable "environment" {
  description = "Environment value"
  default     = "dev"
  type        = string
}

variable "vpc_id" {
  description = "VPC where the pipeline is hosted"
  type        = string
}

variable "subnet_ids" {
  description = "List of subnet ids where to host the pipeline"
  type        = list(string)
}

variable "ecr_force_delete" {
  description = "ECR Delete even if images are present"
  type        = bool
  default     = false
}

variable "sg_compute_additional" {
  description = "Additional egress rules for compute security groups (e.g. connectivity to intranet endpoints)"
  type = list(object({
    from_port   = number
    to_port     = number
    protocol    = string
    cidr_blocks = list(string)
  }))
  default = []
}
