# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: MIT-0

locals {
  create_vpc = var.vpc_id == null
}

data "aws_availability_zones" "available" {
  count = local.create_vpc ? 1 : 0
  state = "available"
}

locals {
  azs             = local.create_vpc ? slice(data.aws_availability_zones.available[0].names, 0, 2) : []
  private_subnets = [for i, az in local.azs : cidrsubnet(var.vpc_cidr, 4, i)]
  public_subnets  = [for i, az in local.azs : cidrsubnet(var.vpc_cidr, 4, i + 2)]

  # Resolved values — either from created resources or from variables
  resolved_vpc_id          = local.create_vpc ? aws_vpc.main[0].id : var.vpc_id
  resolved_subnet_ids      = local.create_vpc ? aws_subnet.private[*].id : var.subnet_ids
  resolved_route_table_ids = local.create_vpc ? [aws_route_table.private[0].id] : var.route_table_ids

  # CIDR blocks for the interface-endpoint security group ingress. When we create
  # the VPC this is the configured CIDR (known at plan time); when reusing an
  # existing VPC we read them from the data source below.
  resolved_vpc_cidr_blocks = local.create_vpc ? [var.vpc_cidr] : [for assoc in data.aws_vpc.existing[0].cidr_block_associations : assoc.cidr_block]
}

# Only read back an existing VPC when the caller supplied one. This data source
# never runs on the VPC-creating path, so it cannot depend on an unknown id.
data "aws_vpc" "existing" {
  count = local.create_vpc ? 0 : 1
  id    = var.vpc_id
}

resource "aws_vpc" "main" {
  count = local.create_vpc ? 1 : 0

  cidr_block           = var.vpc_cidr
  enable_dns_support   = true
  enable_dns_hostnames = true

  tags = {
    Name = "pipeline-vpc-${var.environment}"
  }
}

resource "aws_default_security_group" "default" {
  count = local.create_vpc ? 1 : 0

  vpc_id = aws_vpc.main[0].id

  tags = {
    Name = "pipeline-vpc-default-restricted-${var.environment}"
  }
}

resource "aws_cloudwatch_log_group" "vpc_flow_logs" {
  count = local.create_vpc ? 1 : 0

  name              = "/aws/vpc/flow-logs/pipeline-vpc-${var.environment}"
  retention_in_days = 30
}

resource "aws_iam_role" "vpc_flow_logs" {
  count = local.create_vpc ? 1 : 0

  name = "pipeline-vpc-flow-logs-${var.environment}"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "vpc-flow-logs.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy" "vpc_flow_logs" {
  count = local.create_vpc ? 1 : 0

  name = "vpc-flow-logs-publish"
  role = aws_iam_role.vpc_flow_logs[0].id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Action = [
        "logs:CreateLogStream",
        "logs:PutLogEvents",
        "logs:DescribeLogGroups",
        "logs:DescribeLogStreams"
      ]
      Resource = "${aws_cloudwatch_log_group.vpc_flow_logs[0].arn}:*"
    }]
  })
}

resource "aws_flow_log" "main" {
  count = local.create_vpc ? 1 : 0

  vpc_id               = aws_vpc.main[0].id
  traffic_type         = "ALL"
  iam_role_arn         = aws_iam_role.vpc_flow_logs[0].arn
  log_destination      = aws_cloudwatch_log_group.vpc_flow_logs[0].arn
  log_destination_type = "cloud-watch-logs"

  tags = {
    Name = "pipeline-vpc-flow-log-${var.environment}"
  }
}

# ──────────────────────────────────────────────
# Private subnets (Batch, Lambda, VPC endpoints)
# ──────────────────────────────────────────────

resource "aws_subnet" "private" {
  count = local.create_vpc ? length(local.azs) : 0

  vpc_id            = aws_vpc.main[0].id
  cidr_block        = local.private_subnets[count.index]
  availability_zone = local.azs[count.index]

  tags = {
    Name = "pipeline-private-${local.azs[count.index]}-${var.environment}"
  }
}

# ──────────────────────────────────────────────
# Public subnets (NAT Gateway)
# ──────────────────────────────────────────────

resource "aws_subnet" "public" {
  count = local.create_vpc ? length(local.azs) : 0

  vpc_id                  = aws_vpc.main[0].id
  cidr_block              = local.public_subnets[count.index]
  availability_zone       = local.azs[count.index]
  map_public_ip_on_launch = false

  tags = {
    Name = "pipeline-public-${local.azs[count.index]}-${var.environment}"
  }
}

# ──────────────────────────────────────────────
# Internet Gateway
# ──────────────────────────────────────────────

resource "aws_internet_gateway" "main" {
  count = local.create_vpc ? 1 : 0

  vpc_id = aws_vpc.main[0].id

  tags = {
    Name = "pipeline-igw-${var.environment}"
  }
}

# ──────────────────────────────────────────────
# NAT Gateway (single, in first public subnet)
# ──────────────────────────────────────────────

resource "aws_eip" "nat" {
  count  = local.create_vpc ? 1 : 0
  domain = "vpc"

  tags = {
    Name = "pipeline-nat-eip-${var.environment}"
  }
}

resource "aws_nat_gateway" "main" {
  count = local.create_vpc ? 1 : 0

  allocation_id = aws_eip.nat[0].id
  subnet_id     = aws_subnet.public[0].id

  depends_on = [aws_internet_gateway.main]

  tags = {
    Name = "pipeline-nat-${var.environment}"
  }
}

# ──────────────────────────────────────────────
# Route tables
# ──────────────────────────────────────────────

resource "aws_route_table" "public" {
  count = local.create_vpc ? 1 : 0

  vpc_id = aws_vpc.main[0].id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.main[0].id
  }

  tags = {
    Name = "pipeline-public-rt-${var.environment}"
  }
}

resource "aws_route_table_association" "public" {
  count = local.create_vpc ? length(local.azs) : 0

  subnet_id      = aws_subnet.public[count.index].id
  route_table_id = aws_route_table.public[0].id
}

resource "aws_route_table" "private" {
  count = local.create_vpc ? 1 : 0

  vpc_id = aws_vpc.main[0].id

  route {
    cidr_block     = "0.0.0.0/0"
    nat_gateway_id = aws_nat_gateway.main[0].id
  }

  tags = {
    Name = "pipeline-private-rt-${var.environment}"
  }
}

resource "aws_route_table_association" "private" {
  count = local.create_vpc ? length(local.azs) : 0

  subnet_id      = aws_subnet.private[count.index].id
  route_table_id = aws_route_table.private[0].id
}
