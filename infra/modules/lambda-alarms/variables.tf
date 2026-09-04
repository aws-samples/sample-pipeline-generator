# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: MIT-0

variable "lambda_functions" {
  description = "Map of Lambda function names to their configurations"
  type = map(object({
    function_name           = string
    error_threshold         = optional(number, 1)
    duration_threshold_ms   = optional(number, 5000)
    concurrent_exec_percent = optional(number, 0.9)
  }))
}

variable "account_concurrency_quota" {
  description = "AWS account Lambda concurrency quota for the region"
  type        = number
  default     = 1000
}

variable "tags" {
  description = "Tags to apply to all alarms"
  type        = map(string)
  default     = {}
}
