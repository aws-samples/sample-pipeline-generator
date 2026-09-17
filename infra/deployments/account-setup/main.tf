# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: MIT-0

data "aws_caller_identity" "current" {}
data "aws_region" "current" {}

locals {
  tf_state_bucket_name = "terraform-state-bucket-${data.aws_region.current.region}-${data.aws_caller_identity.current.account_id}"
}

module "bootstrap" {
  source = "../../modules/pipeline-account-bootstrap"

  region = data.aws_region.current.region

  # VPC Endpoints
  vpc_id              = local.resolved_vpc_id
  vpc_subnet_ids      = local.resolved_subnet_ids
  vpc_route_table_ids = local.resolved_route_table_ids
  vpc_cidr_blocks     = local.resolved_vpc_cidr_blocks
  vpc_endpoints       = var.vpc_endpoints

  tags = {
    Environment = var.environment
    Owner       = "workflow-platform"
  }
}
