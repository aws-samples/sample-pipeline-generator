# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: MIT-0

terraform {
  required_version = ">= 1.8"

  required_providers {
    aws = {
      source  = "registry.opentofu.org/hashicorp/aws"
      version = "~> 6.0"
    }
    archive = {
      source  = "registry.opentofu.org/hashicorp/archive"
      version = "~> 2.7"
    }
  }

}
