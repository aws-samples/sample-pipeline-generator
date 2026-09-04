# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: MIT-0

# main.tf

terraform {
  required_providers {
    aws = {
      source  = "registry.opentofu.org/hashicorp/aws"
      version = "~> 6.10"
    }
    random = {
      source  = "registry.opentofu.org/hashicorp/random"
      version = "~> 3.6"
    }
  }
  required_version = "~> 1.13"
}

data "aws_caller_identity" "current" {}

resource "random_id" "suffix" {
  byte_length = 4
}

resource "aws_s3_bucket" "bucket" {
  bucket        = "test-${data.aws_caller_identity.current.account_id}-${random_id.suffix.hex}"
  force_destroy = true
}

resource "aws_s3_bucket_public_access_block" "bucket" {

  bucket = aws_s3_bucket.bucket.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

data "aws_kms_key" "s3" {
  key_id = "alias/aws/s3"
}

# Customer-managed KMS key encrypting the test ECR repository below.
# Even for the test fixture, using a CMK (rather than AWS-managed encryption)
# keeps this file a correct template of production-shaped ECR and satisfies
# CKV_AWS_136.
resource "aws_kms_key" "ecr" {
  description             = "KMS CMK for the pipeline module iac_tests fixture ECR"
  deletion_window_in_days = 7
  enable_key_rotation     = true
  policy                  = data.aws_iam_policy_document.ecr_kms.json

  tags = {
    Repo        = "simple-workflow-generator"
    Environment = "OpenTofu Tests"
  }
}

# AWS-recommended default key policy: delegate authorization to IAM.
# The Resource="*" inside a key policy refers to the containing key itself,
# not to arbitrary AWS resources.
data "aws_iam_policy_document" "ecr_kms" {
  #checkov:skip=CKV_AWS_109:Key policy Resource="*" refers to the key itself, not all resources
  #checkov:skip=CKV_AWS_111:Key policy Resource="*" refers to the key itself, not all resources
  #checkov:skip=CKV_AWS_356:Key policy Resource="*" refers to the key itself, not all resources
  statement {
    sid    = "EnableIAMUserPermissions"
    effect = "Allow"
    principals {
      type        = "AWS"
      identifiers = ["arn:aws:iam::${data.aws_caller_identity.current.account_id}:root"]
    }
    actions   = ["kms:*"]
    resources = ["*"]
  }
}

resource "aws_ecr_repository" "batch_repos" {
  # This is just for integration tests purposes.

  name         = "test-batch-repo-${random_id.suffix.hex}"
  force_delete = true

  encryption_configuration {
    encryption_type = "KMS"
    kms_key         = aws_kms_key.ecr.arn
  }

  image_scanning_configuration {
    scan_on_push = true
  }

  tags = {
    Repo        = "simple-workflow-generator"
    Environment = "OpenTofu Tests"
  }
}
