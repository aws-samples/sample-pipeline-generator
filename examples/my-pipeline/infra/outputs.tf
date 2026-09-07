# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: MIT-0

output "pipeline_step_function_arn" {
  description = "ARN of the pipeline Step Functions state machine"
  value       = module.pipeline.step_function_arn
}

output "s3_bucket_names" {
  description = "Names of the created S3 buckets"
  value = {
    source       = module.pipeline_init.s3_buckets["source"].bucket
    intermediate = module.pipeline_init.s3_buckets["intermediate"].bucket
    output       = module.pipeline_init.s3_buckets["output"].bucket
  }
}
