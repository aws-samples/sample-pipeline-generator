# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: MIT-0

# Output bucket name for backend configuration
output "s3_tf_state_bucket_name" {
  value       = aws_s3_bucket.terraform_state.bucket
  description = "OpenTofu State file bucket name"
}

# ──────────────────────────────────────────────
# VPC
# ──────────────────────────────────────────────

output "vpc_id" {
  description = "ID of the pipeline VPC"
  value       = local.resolved_vpc_id
}

output "private_subnet_ids" {
  description = "IDs of the private subnets (use for pipeline vpc_id/subnet_ids)"
  value       = local.resolved_subnet_ids
}

output "public_subnet_ids" {
  description = "IDs of the public subnets (empty when using an existing VPC)"
  value       = aws_subnet.public[*].id
}

# ──────────────────────────────────────────────
# VPC Endpoints
# ──────────────────────────────────────────────

output "gateway_endpoint_ids" {
  description = "Map of gateway VPC endpoint names to their IDs"
  value       = module.bootstrap.gateway_endpoint_ids
}

output "interface_endpoint_ids" {
  description = "Map of interface VPC endpoint names to their IDs"
  value       = module.bootstrap.interface_endpoint_ids
}

output "vpc_endpoints_security_group_id" {
  description = "ID of the security group used by interface VPC endpoints"
  value       = module.bootstrap.vpc_endpoints_security_group_id
}
