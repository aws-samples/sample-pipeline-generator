# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: MIT-0

module "shared_ecr" {
  source = "../../modules/central-ecr"

  allowed_account_ids = [data.aws_caller_identity.current.account_id]
  ecr_repositories    = ["copy-intermediate-to-output"]
  ecr_force_delete    = true
}
