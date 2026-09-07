# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: MIT-0

terraform {
  required_providers {
    aws = {
      source  = "registry.opentofu.org/hashicorp/aws"
      version = "~> 6.0"
    }
  }

  # ─────────────────────────────────────────────────────────────────────────
  # Bootstrap procedure for a fresh account (chicken-and-egg on the state
  # bucket — this deployment CREATES its own backend):
  #
  #   1. Leave `backend "s3" {}` COMMENTED OUT below.
  #   2. Run `make deploy-account-setup`. State is written locally (relative
  #      to this directory) and the S3 state bucket + KMS key + bucket policy
  #      are provisioned.
  #   3. UNCOMMENT the `backend "s3" {}` line below.
  #   4. Run `make deploy-account-setup` again. OpenTofu prompts to migrate
  #      the local state into the newly-created S3 bucket — answer "yes".
  #      From this point on the state lives remotely and is encrypted with
  #      the CMK provisioned in step 2.
  #
  # In steady state (bucket exists, migration done) this line stays
  # uncommented and `env/<env>/backend.tfvars` supplies bucket / key / region
  # to `tofu init -backend-config=...`.
  # ─────────────────────────────────────────────────────────────────────────
  # backend "s3" {}

  required_version = ">= 1.8"
}

provider "aws" {
  region = var.region

  default_tags {
    tags = {
      DeployedBy = "OpenTofu"
      Repository = "simple-workflow-generator"
      Code       = "account-setup"
    }
  }
}
