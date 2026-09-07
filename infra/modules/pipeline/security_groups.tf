# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: MIT-0

# Security Group for Processing Jobs
# Always needs to pe provisioned to initialize the compute environment.
resource "aws_security_group" "batch_steps" {
  name_prefix = "${local.pipeline_name}-${local.environment}-batch-steps-"
  vpc_id      = var.vpc_id
  description = "Security Group for AWS Batch pipeline steps"

  egress {
    description     = "HTTPS to S3"
    from_port       = 443
    to_port         = 443
    protocol        = "tcp"
    prefix_list_ids = [data.aws_prefix_list.s3.id]
  }

  egress {
    description = "HTTPS to VPC services (ECR, CloudWatch)"
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = [for assoc in data.aws_vpc.selected.cidr_block_associations : assoc.cidr_block]
  }

  dynamic "egress" {
    for_each = var.sg_compute_additional
    content {
      description = "Connectivity to intranet"
      from_port   = egress.value["from_port"]
      to_port     = egress.value["to_port"]
      protocol    = egress.value["protocol"]
      cidr_blocks = egress.value["cidr_blocks"]
    }
  }

  tags = merge(local.common_tags, {
    Name = "${local.pipeline_name}-${local.environment}-compute-sg"
  })
}

# Security Group for Lambda steps. It is kept separate because of attached ENIs deletion.
resource "aws_security_group" "lambda_steps" {
  #checkov:skip=CKV2_AWS_5:Security group is conditionally attached to Lambda steps if those exist
  count = length(local.lambda_steps) > 0 ? 1 : 0

  name_prefix = "${local.pipeline_name}-${local.environment}-lambda-steps-"
  vpc_id      = var.vpc_id
  description = "Security Group for Lambda pipeline steps"

  egress {
    description     = "HTTPS to S3"
    from_port       = 443
    to_port         = 443
    protocol        = "tcp"
    prefix_list_ids = [data.aws_prefix_list.s3.id]
  }

  egress {
    description = "HTTPS to VPC services (ECR, CloudWatch)"
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = [for assoc in data.aws_vpc.selected.cidr_block_associations : assoc.cidr_block]
  }

  dynamic "egress" {
    for_each = var.sg_compute_additional
    content {
      description = "Connectivity to intranet"
      from_port   = egress.value["from_port"]
      to_port     = egress.value["to_port"]
      protocol    = egress.value["protocol"]
      cidr_blocks = egress.value["cidr_blocks"]
    }
  }

  tags = merge(local.common_tags, {
    Name = "${local.pipeline_name}-${local.environment}-lambda-steps-sg"
  })

  lifecycle {
    create_before_destroy = true
  }
}
