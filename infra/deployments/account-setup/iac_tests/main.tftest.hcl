# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: MIT-0

variables {
  region      = "us-east-1"
  environment = "test"

  # No VPC endpoints under test — an empty list also skips the
  # `data.aws_vpc.selected` lookup inside the bootstrap module.
  vpc_endpoints = []
}

# Static fake credentials plus overrides for the three account/region lookups
# keep `tofu test` hermetic — the assertions below only inspect plan-time policy
# documents and resource arguments, so no AWS call is needed.
provider "aws" {
  region                      = "us-east-1"
  access_key                  = "mock_access_key"
  secret_key                  = "mock_secret_key"
  skip_credentials_validation = true
  skip_requesting_account_id  = true
  skip_metadata_api_check     = true
}

override_data {
  target = data.aws_caller_identity.current
  values = {
    account_id = "123456789012"
    arn        = "arn:aws:iam::123456789012:root"
    id         = "123456789012"
    user_id    = "123456789012"
  }
}

override_data {
  target = data.aws_region.current
  values = {
    id     = "us-east-1"
    region = "us-east-1"
    name   = "us-east-1"
  }
}

override_data {
  target = data.aws_availability_zones.available
  values = {
    names = ["us-east-1a", "us-east-1b"]
  }
}

override_data {
  target = module.shared_ecr.data.aws_caller_identity.current
  values = {
    account_id = "123456789012"
    arn        = "arn:aws:iam::123456789012:root"
    id         = "123456789012"
    user_id    = "123456789012"
  }
}

run "state_bucket" {
  command = plan

  assert {
    condition     = strcontains(aws_s3_bucket.terraform_state.bucket, "terraform-state-bucket-us-east-1-")
    error_message = "State bucket name must follow 'terraform-state-bucket-<region>-<account>' convention"
  }

  assert {
    condition     = aws_s3_bucket_versioning.terraform_state.versioning_configuration[0].status == "Enabled"
    error_message = "Versioning must be enabled on the state bucket"
  }

  assert {
    condition     = aws_s3_bucket_public_access_block.terraform_state.block_public_acls == true
    error_message = "Public access block must block public ACLs"
  }

  assert {
    condition     = aws_s3_bucket_public_access_block.terraform_state.block_public_policy == true
    error_message = "Public access block must block public bucket policies"
  }

  assert {
    condition     = aws_s3_bucket_public_access_block.terraform_state.ignore_public_acls == true
    error_message = "Public access block must ignore public ACLs"
  }

  assert {
    condition     = aws_s3_bucket_public_access_block.terraform_state.restrict_public_buckets == true
    error_message = "Public access block must restrict public buckets"
  }
}

run "state_bucket_lifecycle" {
  command = plan

  assert {
    condition     = length(aws_s3_bucket_lifecycle_configuration.terraform_state.rule) == 2
    error_message = "Lifecycle configuration must define exactly 2 rules (noncurrent expiration + multipart abort)"
  }

  assert {
    condition     = aws_s3_bucket_lifecycle_configuration.terraform_state.rule[0].id == "expire-noncurrent-versions-after-90-days"
    error_message = "First lifecycle rule must be the noncurrent-version expiration"
  }

  assert {
    condition     = aws_s3_bucket_lifecycle_configuration.terraform_state.rule[0].status == "Enabled"
    error_message = "Noncurrent-version expiration rule must be Enabled"
  }

  assert {
    condition     = aws_s3_bucket_lifecycle_configuration.terraform_state.rule[0].noncurrent_version_expiration[0].noncurrent_days == 90
    error_message = "Noncurrent versions must be expired after 90 days (~3 months)"
  }

  assert {
    condition     = length(aws_s3_bucket_lifecycle_configuration.terraform_state.rule[0].expiration) == 0
    error_message = "Noncurrent-version rule must NOT define a current-version expiration block (current versions must be retained)"
  }

  assert {
    condition     = aws_s3_bucket_lifecycle_configuration.terraform_state.rule[1].id == "abort-incomplete-multipart-uploads-after-7-days"
    error_message = "Second lifecycle rule must be the abort-incomplete-multipart-upload rule"
  }

  assert {
    condition     = aws_s3_bucket_lifecycle_configuration.terraform_state.rule[1].abort_incomplete_multipart_upload[0].days_after_initiation == 7
    error_message = "Incomplete multipart uploads must be aborted 7 days after initiation"
  }
}

run "state_bucket_encryption" {
  command = plan

  # `rule` is a set, so it has no addressable index — match on the element.
  assert {
    condition = length([
      for r in aws_s3_bucket_server_side_encryption_configuration.terraform_state.rule :
      r if one(r.apply_server_side_encryption_by_default).sse_algorithm == "aws:kms"
    ]) == 1
    error_message = "State bucket must be encrypted with KMS (aws:kms)"
  }


  assert {
    condition     = aws_kms_key.s3_encryption.enable_key_rotation == true
    error_message = "KMS key for state-bucket encryption must have automatic rotation enabled"
  }

  assert {
    condition     = aws_kms_key.s3_encryption.deletion_window_in_days == 7
    error_message = "KMS key deletion window must be 7 days"
  }

  assert {
    condition     = aws_kms_alias.s3_encryption.name == "alias/tf-backend-test-s3"
    error_message = "KMS alias must follow 'alias/tf-backend-<environment>-s3' pattern"
  }
}

# The rendered `.json` of both documents is provider-computed and therefore
# unknown at plan time, so these runs assert on the `statement` blocks instead.

# Default (empty) state_backend_principals: same-account callers already reach
# the bucket and key via their own IAM policies, so no Allow statement is
# emitted and only the guardrails remain.
run "state_backend_access_policies_default" {
  command = plan

  assert {
    condition     = [for st in data.aws_iam_policy_document.terraform_state.statement : st.sid] == ["DenyInsecureTransport"]
    error_message = "Bucket policy must contain only DenyInsecureTransport when state_backend_principals is empty"
  }

  assert {
    condition     = [for st in data.aws_iam_policy_document.s3_encryption_key.statement : st.sid] == ["Enable IAM User Permissions"]
    error_message = "KMS key policy must contain only the account-root statement when state_backend_principals is empty"
  }

  # The TLS guardrail is unconditional and must survive an empty principal list.
  assert {
    condition     = one(data.aws_iam_policy_document.terraform_state.statement).effect == "Deny"
    error_message = "The remaining bucket-policy statement must be a Deny"
  }

  assert {
    condition     = one(one(data.aws_iam_policy_document.terraform_state.statement).condition).variable == "aws:SecureTransport"
    error_message = "Bucket policy must deny non-TLS access via aws:SecureTransport"
  }

}

# Populated state_backend_principals: the dynamic Allow statements appear and
# carry every supplied principal (the cross-account grant path).
run "state_backend_access_policies_with_principals" {
  command = plan

  variables {
    state_backend_principals = [
      "arn:aws:iam::123456789012:role/StateBackendWriter",
      "arn:aws:iam::123456789012:role/StateBackendReader",
    ]
  }

  assert {
    condition = [for st in data.aws_iam_policy_document.terraform_state.statement : st.sid] == [
      "AllowStateBackendRolesBucketAccess",
      "AllowStateBackendRolesObjectAccess",
      "DenyInsecureTransport",
    ]
    error_message = "Bucket policy must add both Allow statements ahead of the TLS deny when principals are supplied"
  }

  assert {
    condition = [for st in data.aws_iam_policy_document.s3_encryption_key.statement : st.sid] == [
      "Enable IAM User Permissions",
      "AllowStateBackendRolesUseOfKey",
    ]
    error_message = "KMS key policy must add the key-use Allow statement when principals are supplied"
  }

  # Every supplied principal must reach both Allow statements, not just the first.
  assert {
    condition = alltrue([
      for st in data.aws_iam_policy_document.terraform_state.statement :
      length(setsubtract(one(st.principals).identifiers, var.state_backend_principals)) == 0 &&
      length(setsubtract(var.state_backend_principals, one(st.principals).identifiers)) == 0
      if st.effect == "Allow"
    ])
    error_message = "Both bucket-policy Allow statements must carry every supplied principal"
  }

  assert {
    condition = alltrue([
      for st in data.aws_iam_policy_document.s3_encryption_key.statement :
      length(setsubtract(one(st.principals).identifiers, var.state_backend_principals)) == 0 &&
      length(setsubtract(var.state_backend_principals, one(st.principals).identifiers)) == 0
      if st.sid == "AllowStateBackendRolesUseOfKey"
    ])
    error_message = "The KMS key-use statement must carry every supplied principal"
  }
}

run "shared_ecr_module" {
  command = plan

  assert {
    condition     = length(module.shared_ecr.shared_ecrs) == 1
    error_message = "shared_ecr module must expose exactly the 'copy-intermediate-to-output' repository"
  }
}

# var.vpc_id defaults to null, so the VPC and its flow-log role are created.
run "vpc_created_by_default" {
  command = plan

  assert {
    condition     = length(aws_vpc.main) == 1
    error_message = "A VPC must be created when var.vpc_id is not supplied"
  }

  assert {
    condition     = aws_vpc.main[0].tags["Name"] == "pipeline-vpc-test"
    error_message = "VPC name tag must follow 'pipeline-vpc-<environment>' convention"
  }

  assert {
    condition     = aws_iam_role.vpc_flow_logs[0].name == "pipeline-vpc-flow-logs-test"
    error_message = "Flow-logs role name must follow 'pipeline-vpc-flow-logs-<environment>' convention"
  }

  assert {
    condition     = length(aws_flow_log.main) == 1
    error_message = "VPC flow logging must be enabled on a created VPC"
  }
}

# Supplying an existing vpc_id must skip VPC creation entirely.
run "vpc_skipped_when_provided" {
  command = plan

  variables {
    vpc_id          = "vpc-0123456789abcdef0"
    subnet_ids      = ["subnet-0123456789abcdef0"]
    route_table_ids = ["rtb-0123456789abcdef0"]
  }

  assert {
    condition     = length(aws_vpc.main) == 0
    error_message = "No VPC must be created when var.vpc_id is supplied"
  }

  assert {
    condition     = length(aws_iam_role.vpc_flow_logs) == 0
    error_message = "No flow-logs role must be created when using an existing VPC"
  }

  assert {
    condition     = length(aws_nat_gateway.main) == 0
    error_message = "No NAT gateway must be created when using an existing VPC"
  }
}

# The flow-logs role is service-assumed by vpc-flow-logs.amazonaws.com and is the
# only role this deployment creates, so no human-assumable admin role exists.
run "no_admin_role_is_created" {
  command = plan

  assert {
    condition     = aws_iam_role.vpc_flow_logs[0].name == "pipeline-vpc-flow-logs-test"
    error_message = "The flow-logs role must be the only IAM role this deployment creates"
  }

  assert {
    condition     = strcontains(aws_iam_role.vpc_flow_logs[0].assume_role_policy, "vpc-flow-logs.amazonaws.com")
    error_message = "The flow-logs role must only be assumable by the VPC flow-logs service"
  }

  assert {
    condition     = !strcontains(aws_iam_role.vpc_flow_logs[0].assume_role_policy, ":root")
    error_message = "No role in this deployment may be assumable by the account root principal"
  }
}
