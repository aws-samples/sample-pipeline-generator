# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: MIT-0

variable "ecr_force_delete" {
  description = "Force delete ECR repositories even if they contain images"
  type        = bool
  default     = false
}

variable "ecr_scan_on_push" {
  description = "Enable Amazon ECR basic scanning on image push for shared repositories."
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

variable "allowed_account_ids" {
  description = "List of AWS account IDs allowed to pull images from ECR"
  type        = list(string)
}

variable "ecr_repositories" {
  description = "Name of ECR repositories"
  type        = list(string)
}
