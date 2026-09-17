# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: MIT-0

variables {
  region = "us-east-1"
  tags = {
    Environment = "test"
    Owner       = "workflow-platform"
  }
  vpc_id              = "vpc-0123456789abcdef0"
  vpc_subnet_ids      = ["subnet-0123456789abcdef0", "subnet-0123456789abcdef1"]
  vpc_route_table_ids = ["rtb-0123456789abcdef0"]
  vpc_cidr_blocks     = ["10.0.0.0/16"]
}

# All runs are plan-mode with the sole data source overridden, so no real AWS access is needed.
provider "aws" {
  region                      = "us-east-1"
  access_key                  = "mock"
  secret_key                  = "mock"
  skip_credentials_validation = true
  skip_requesting_account_id  = true
  skip_metadata_api_check     = true
}

run "tags_must_include_owner" {
  command = plan

  variables {
    tags = {
      Environment = "test"
    }
  }

  expect_failures = [
    var.tags
  ]
}

run "tags_must_have_non_empty_owner" {
  command = plan

  variables {
    tags = {
      Owner = ""
    }
  }

  expect_failures = [
    var.tags
  ]
}

run "invalid_endpoint_type_rejected" {
  command = plan

  variables {
    vpc_endpoints = ["s3", "invalid-endpoint"]
  }

  expect_failures = [
    var.vpc_endpoints
  ]
}

run "no_endpoints_creates_nothing" {
  command = plan

  variables {
    vpc_endpoints = []
  }

  assert {
    condition     = length(aws_vpc_endpoint.gateway) == 0
    error_message = "No gateway endpoints must be created when vpc_endpoints is empty"
  }

  assert {
    condition     = length(aws_vpc_endpoint.interface) == 0
    error_message = "No interface endpoints must be created when vpc_endpoints is empty"
  }

  assert {
    condition     = length(aws_security_group.vpc_endpoints) == 0
    error_message = "The endpoints security group must not be created when vpc_endpoints is empty"
  }
}

run "gateway_only_endpoints_skip_security_group" {
  command = plan

  variables {
    vpc_endpoints = ["s3", "dynamodb"]
  }

  assert {
    condition     = length(aws_vpc_endpoint.gateway) == 2
    error_message = "s3 and dynamodb must both be created as gateway endpoints"
  }

  assert {
    condition     = length(aws_vpc_endpoint.interface) == 0
    error_message = "Gateway-only requests must not create interface endpoints"
  }

  assert {
    condition     = length(aws_security_group.vpc_endpoints) == 0
    error_message = "The endpoints security group must not be created without interface endpoints"
  }

  assert {
    condition     = aws_vpc_endpoint.gateway["s3"].vpc_endpoint_type == "Gateway"
    error_message = "The s3 endpoint must be of type Gateway"
  }

  assert {
    condition     = aws_vpc_endpoint.gateway["s3"].service_name == "com.amazonaws.us-east-1.s3"
    error_message = "The s3 endpoint must target the regional S3 service"
  }

  assert {
    condition     = contains(aws_vpc_endpoint.gateway["dynamodb"].route_table_ids, "rtb-0123456789abcdef0")
    error_message = "Gateway endpoints must attach to the provided route tables"
  }
}

run "endpoint_aliases_expand_and_split_by_type" {
  command = plan

  variables {
    vpc_endpoints = ["s3", "ecr", "cloudwatch", "stepfunctions"]
  }

  assert {
    condition     = local.requested_endpoints == toset(["s3", "ecr_api", "ecr_dkr", "cloudwatch_logs", "cloudwatch_monitoring", "stepfunctions"])
    error_message = "ecr must expand to ecr_api+ecr_dkr and cloudwatch to logs+monitoring"
  }

  assert {
    condition     = keys(aws_vpc_endpoint.gateway) == ["s3"]
    error_message = "Only s3 must be a gateway endpoint in this configuration"
  }

  assert {
    condition     = length(aws_vpc_endpoint.interface) == 5
    error_message = "ecr_api, ecr_dkr, cloudwatch_logs, cloudwatch_monitoring and stepfunctions must be interface endpoints"
  }

  assert {
    condition     = aws_vpc_endpoint.interface["ecr_api"].service_name == "com.amazonaws.us-east-1.ecr.api"
    error_message = "ecr_api must target the regional ECR API service"
  }

  assert {
    condition     = aws_vpc_endpoint.interface["ecr_dkr"].service_name == "com.amazonaws.us-east-1.ecr.dkr"
    error_message = "ecr_dkr must target the regional ECR Docker registry service"
  }

  assert {
    condition     = aws_vpc_endpoint.interface["cloudwatch_logs"].service_name == "com.amazonaws.us-east-1.logs"
    error_message = "cloudwatch_logs must target the regional CloudWatch Logs service"
  }

  assert {
    condition     = aws_vpc_endpoint.interface["cloudwatch_monitoring"].service_name == "com.amazonaws.us-east-1.monitoring"
    error_message = "cloudwatch_monitoring must target the regional CloudWatch monitoring service"
  }

  assert {
    condition     = aws_vpc_endpoint.interface["stepfunctions"].private_dns_enabled == true
    error_message = "Interface endpoints must enable private DNS"
  }

  assert {
    condition     = alltrue([for k, v in aws_vpc_endpoint.interface : v.vpc_endpoint_type == "Interface"])
    error_message = "All expanded alias endpoints must be of type Interface"
  }

  assert {
    condition     = alltrue([for k, v in aws_vpc_endpoint.interface : contains(v.subnet_ids, "subnet-0123456789abcdef0")])
    error_message = "Interface endpoints must attach to the provided subnets"
  }
}

run "interface_endpoints_create_security_group" {
  command = plan

  variables {
    vpc_endpoints = ["ecr"]
  }

  assert {
    condition     = length(aws_security_group.vpc_endpoints) == 1
    error_message = "Interface endpoints must create the shared endpoints security group"
  }

  assert {
    condition     = aws_security_group.vpc_endpoints[0].name_prefix == "vpc-endpoints-"
    error_message = "The endpoints security group must use the vpc-endpoints- name prefix"
  }

  assert {
    condition     = aws_security_group.vpc_endpoints[0].tags["Owner"] == "workflow-platform"
    error_message = "The endpoints security group must inherit the Owner tag"
  }

  assert {
    condition     = one(aws_security_group.vpc_endpoints[0].ingress[*].from_port) == 443
    error_message = "The endpoints security group must allow HTTPS ingress only"
  }

  assert {
    condition     = contains(one(aws_security_group.vpc_endpoints[0].ingress[*].cidr_blocks), "10.0.0.0/16")
    error_message = "HTTPS ingress must be scoped to the VPC CIDR blocks"
  }
}

run "security_group_ingress_uses_provided_cidr_blocks" {
  command = plan

  variables {
    vpc_endpoints   = ["ecr"]
    vpc_cidr_blocks = ["10.1.0.0/16", "10.2.0.0/16"]
  }

  assert {
    condition     = one(aws_security_group.vpc_endpoints[0].ingress[*].cidr_blocks) == tolist(["10.1.0.0/16", "10.2.0.0/16"])
    error_message = "HTTPS ingress must be scoped to the provided vpc_cidr_blocks"
  }
}
