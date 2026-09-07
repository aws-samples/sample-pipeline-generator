<!-- Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved. SPDX-License-Identifier: MIT-0 -->

# account-setup

Bootstraps an AWS account for pipeline deployments. This is the **first deployment** that must be applied in any new account — all other deployments depend on the resources it creates.

## What it does

1. **OpenTofu state backend** — an encrypted, versioned S3 bucket with a dedicated KMS key where all OpenTofu deployments store their state.

2. **VPC** (conditional) — a full VPC with private subnets (for Batch, Lambda, VPC endpoints), public subnets, NAT Gateway for outbound internet, and VPC flow logging. Skipped if you provide an existing `vpc_id`.

3. **VPC endpoints** — private connectivity to AWS services (ECR, CloudWatch, SSM, Secrets Manager, S3) so pipeline workloads in private subnets minimize internet traffic.

4. **Shared ECR repositories** — the `copy-intermediate-to-output` container image used by pipelines with `copy_to_target` enabled.

Deploy with whatever credentials you already use for the account — see
[Prerequisites](#prerequisites). The only IAM role this deployment provisions is the
VPC flow-logs service role, assumable solely by `vpc-flow-logs.amazonaws.com`.

## Quick start

### First-time bootstrap (fresh account, state bucket does not exist)

This deployment provisions its own OpenTofu state backend, so the very first
apply must run with the S3 backend disabled — otherwise `tofu init` would try
to read state from a bucket that does not exist yet.

From `infra/deployments/`:

1. **Create the `.tfvars` files from the shipped templates.** Only `*.tfvars.example`
   files are committed — the real `backend.tfvars` and `inputs.tfvars` are gitignored,
   so you must create them yourself.

   ```bash
   cd account-setup/env/dev
   cp backend.tfvars.example backend.tfvars
   cp inputs.tfvars.example  inputs.tfvars
   $EDITOR backend.tfvars inputs.tfvars    # replace <REGION>/<ACCOUNT_ID> placeholders
   cd ../../..                             # back to infra/deployments/
   ```

   At minimum set `region` in both files (it is required and has no default). `backend.tfvars`
   is only consumed once the S3 backend is enabled (steps 3–4), but both files must exist for
   the Makefile's `tofu init`/`tofu plan` to run.
2. Confirm `account-setup/terraform.tf` has the `backend "s3" {}` line **commented out** (it ships that way).
3. Apply account-setup with local state:

   ```bash
   make deploy-account-setup      # Creates state bucket, KMS key, IAM, VPC, ECR
   ```

4. **Uncomment** the `backend "s3" {}` line in `account-setup/terraform.tf`.
5. Re-apply account-setup. OpenTofu will detect the new backend and prompt to migrate the local state into the S3 bucket — answer **yes**. From this point on the state file is stored remotely and encrypted with the CMK provisioned in step 3.

   ```bash
   make deploy-account-setup      # Migrates local state -> S3, then plans no changes
   ```

6. Build and push the shared container image:

   ```bash
   make deploy-shared
   ```

### Steady state (state bucket exists, backend uncommented)

```bash
make all                          # deploy-account-setup + deploy-shared
```

## Prerequisites

- AWS CLI configured with credentials that have admin access to the target account
- OpenTofu >= 1.8
- Container runtime (`docker`, `finch`, or `podman`)

## Inputs

| Name | Description | Type | Default | Required |
|------|-------------|------|---------|----------|
| `region` | AWS region for all resources | `string` | — | yes |
| `environment` | Environment name (e.g. dev, staging, prod) | `string` | `"dev"` | no |
| `state_backend_principals` | IAM principal ARNs granted read/write on the state bucket and use of its KMS key. Empty omits the Allow statements | `list(string)` | `[]` | no |
| `vpc_id` | Existing VPC ID (skips VPC creation when set) | `string` | `null` | no |
| `subnet_ids` | Existing private subnet IDs (required when `vpc_id` is provided) | `list(string)` | `[]` | no |
| `route_table_ids` | Existing route table IDs (required when `vpc_id` is provided) | `list(string)` | `[]` | no |
| `vpc_cidr` | CIDR block for the VPC (only used when creating a new VPC) | `string` | `"10.0.0.0/16"` | no |
| `vpc_endpoints` | Endpoint types to create | `list(string)` | `["s3", "ecr", "cloudwatch", "ssm", "secretsmanager"]` | no |

## Outputs

| Name | Description |
|------|-------------|
| `s3_tf_state_bucket_name` | OpenTofu state file bucket name |
| `vpc_id` | ID of the pipeline VPC (created or provided) |
| `private_subnet_ids` | IDs of the private subnets |
| `public_subnet_ids` | IDs of the public subnets (empty when using an existing VPC) |
| `gateway_endpoint_ids` | Map of gateway VPC endpoint names to their IDs |
| `interface_endpoint_ids` | Map of interface VPC endpoint names to their IDs |
| `vpc_endpoints_security_group_id` | ID of the security group used by interface VPC endpoints |

## State bucket details

- **Versioning** enabled
- **Server-side encryption** with a dedicated customer-managed KMS key (`alias/tf-backend-<environment>-s3`, key rotation enabled)
- **Public access** fully blocked
- **Lifecycle**: noncurrent object versions expire after 90 days (the live state file is retained indefinitely); incomplete multipart uploads aborted after 7 days
- **Access**: non-TLS requests are denied. Same-account principals reach the bucket and its KMS key through their own IAM policies, so no bucket-policy `Allow` is emitted by default. Set `state_backend_principals` to grant additional (for example cross-account) principals read/write on the bucket and use of the key.

## After deployment

Use the outputs to configure your pipeline examples:

```hcl
# In examples/<pipeline>/env/dev/inputs.tfvars
region     = "us-east-1"
vpc_id     = "<vpc_id output>"
subnet_ids = <private_subnet_ids output>
```
