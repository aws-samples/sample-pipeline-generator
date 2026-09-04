# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: MIT-0

# ──────────────────────────────────────────────
# VPC Endpoints
# ──────────────────────────────────────────────

output "gateway_endpoint_ids" {
  description = "Map of gateway VPC endpoint names to their IDs"
  value       = { for k, v in aws_vpc_endpoint.gateway : k => v.id }
}

output "interface_endpoint_ids" {
  description = "Map of interface VPC endpoint names to their IDs"
  value       = { for k, v in aws_vpc_endpoint.interface : k => v.id }
}

output "vpc_endpoints_security_group_id" {
  description = "ID of the security group used by interface VPC endpoints"
  value       = try(aws_security_group.vpc_endpoints[0].id, null)
}
