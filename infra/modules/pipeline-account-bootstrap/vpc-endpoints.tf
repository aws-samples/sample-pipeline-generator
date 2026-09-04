# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: MIT-0

locals {
  supported_endpoints = {
    s3 = {
      service     = "com.amazonaws.${var.region}.s3"
      type        = "Gateway"
      private_dns = false
    }
    dynamodb = {
      service     = "com.amazonaws.${var.region}.dynamodb"
      type        = "Gateway"
      private_dns = false
    }
    ecr_api = {
      service     = "com.amazonaws.${var.region}.ecr.api"
      type        = "Interface"
      private_dns = true
    }
    ecr_dkr = {
      service     = "com.amazonaws.${var.region}.ecr.dkr"
      type        = "Interface"
      private_dns = true
    }
    stepfunctions = {
      service     = "com.amazonaws.${var.region}.states"
      type        = "Interface"
      private_dns = true
    }
    cloudwatch_logs = {
      service     = "com.amazonaws.${var.region}.logs"
      type        = "Interface"
      private_dns = true
    }
    cloudwatch_monitoring = {
      service     = "com.amazonaws.${var.region}.monitoring"
      type        = "Interface"
      private_dns = true
    }
    ssm = {
      service     = "com.amazonaws.${var.region}.ssm"
      type        = "Interface"
      private_dns = true
    }
    secretsmanager = {
      service     = "com.amazonaws.${var.region}.secretsmanager"
      type        = "Interface"
      private_dns = true
    }
  }

  # "ecr" expands to ecr_api + ecr_dkr, "cloudwatch" expands to logs + monitoring, others map 1:1
  requested_endpoints = toset(flatten([
    for e in var.vpc_endpoints : (
      e == "ecr" ? ["ecr_api", "ecr_dkr"] :
      e == "cloudwatch" ? ["cloudwatch_logs", "cloudwatch_monitoring"] :
      [e]
    )
  ]))

  gateway_endpoints   = { for k in local.requested_endpoints : k => local.supported_endpoints[k] if local.supported_endpoints[k].type == "Gateway" }
  interface_endpoints = { for k in local.requested_endpoints : k => local.supported_endpoints[k] if local.supported_endpoints[k].type == "Interface" }

  create_endpoints = length(var.vpc_endpoints) > 0
}

data "aws_vpc" "selected" {
  count = local.create_endpoints ? 1 : 0
  id    = var.vpc_id
}

# ──────────────────────────────────────────────
# Security group for interface endpoints
# ──────────────────────────────────────────────

# Checkov struggles with the dynamic count of VPC endpoints. Practically, the security group will not be created
# if no VPC endpoint is declared.
resource "aws_security_group" "vpc_endpoints" {
  #checkov:skip=CKV2_AWS_5:SG is attached to aws_vpc_endpoint.interface resources via security_group_ids
  count = local.create_endpoints && length(local.interface_endpoints) > 0 ? 1 : 0

  name_prefix = "vpc-endpoints-"
  description = "Security group for interface VPC endpoints"
  vpc_id      = var.vpc_id

  ingress {
    description = "HTTPS from VPC"
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = [for assoc in data.aws_vpc.selected[0].cidr_block_associations : assoc.cidr_block]
  }

  tags = merge(var.tags, {
    Name = "vpc-endpoints"
  })

  lifecycle {
    create_before_destroy = true
  }
}

# ──────────────────────────────────────────────
# Gateway endpoints (S3, DynamoDB)
# ──────────────────────────────────────────────

resource "aws_vpc_endpoint" "gateway" {
  for_each = local.create_endpoints ? local.gateway_endpoints : {}

  vpc_id            = var.vpc_id
  service_name      = each.value.service
  vpc_endpoint_type = "Gateway"
  route_table_ids   = var.vpc_route_table_ids

  tags = merge(var.tags, {
    Name = each.key
  })
}

# ──────────────────────────────────────────────
# Interface endpoints (ECR, Step Functions)
# ──────────────────────────────────────────────

resource "aws_vpc_endpoint" "interface" {
  for_each = local.create_endpoints ? local.interface_endpoints : {}

  vpc_id              = var.vpc_id
  service_name        = each.value.service
  vpc_endpoint_type   = "Interface"
  subnet_ids          = var.vpc_subnet_ids
  security_group_ids  = [aws_security_group.vpc_endpoints[0].id]
  private_dns_enabled = each.value.private_dns

  tags = merge(var.tags, {
    Name = each.key
  })
}
