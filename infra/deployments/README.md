<!-- Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved. SPDX-License-Identifier: MIT-0 -->

# Deployments

Account-level infrastructure setup. This directory contains the OpenTofu root module for bootstrapping a new AWS account and the Makefile that drives it.

## Directory structure

```
deployments/
├── Makefile                             # Build/deploy interface
└── account-setup/                       # AWS account bootstrap (VPC, state bucket, ECR, IAM)
```

The `account-setup/` deployment contains:

| File | Purpose |
|------|---------|
| `main.tf` | Module instantiation and resource definitions |
| `variables.tf` | Input variable declarations |
| `outputs.tf` | Outputs (VPC ID, subnet IDs, endpoint IDs) |
| `terraform.tf` | Provider and backend configuration |
| `backend.tf` | OpenTofu state bucket, KMS key, bucket and key policies |
| `vpc.tf` | VPC, subnets, NAT Gateway, route tables, flow logs |
| `ecr.tf` | Shared ECR repositories |
| `env/<environment>/` | Per-environment config. Ships `backend.tfvars.example` and `inputs.tfvars.example` only — copy each to `backend.tfvars` / `inputs.tfvars` (gitignored) before deploying |

## Makefile

Run `make help` from this directory for the full reference.

### Quick start (first time — fresh account)

The `account-setup` deployment provisions its own OpenTofu state backend, so the first apply must run with the S3 backend disabled — the bucket does not exist yet. This is a **two-pass** procedure:

1. Create the deployment's `.tfvars` files from the shipped templates. Only the
   `*.tfvars.example` files are committed (`*.tfvars` is gitignored).

   ```bash
   cp account-setup/env/dev/backend.tfvars.example account-setup/env/dev/backend.tfvars
   cp account-setup/env/dev/inputs.tfvars.example  account-setup/env/dev/inputs.tfvars
   # Edit both: set region (required, no default) and replace the <REGION>/<ACCOUNT_ID> placeholders
   ```

2. Ensure `account-setup/terraform.tf` has `backend "s3" {}` **commented out** (ships that way).
3. Apply with local state — creates the state bucket, KMS key, IAM, VPC, ECR:

   ```bash
   make deploy-account-setup
   ```

4. **Uncomment** `backend "s3" {}` in `account-setup/terraform.tf`.
5. Re-apply — OpenTofu prompts to migrate local state into the S3 bucket, answer **yes**:

   ```bash
   make deploy-account-setup
   ```

6. Build and push the shared image:

   ```bash
   make deploy-shared
   ```

Once state is in S3 you can use `make all` (below) for subsequent runs.

### Steady state

```bash
make all
```

Runs `deploy-account-setup` then `deploy-shared`. State is read from and written to the S3 bucket configured in `account-setup/env/<env>/backend.tfvars`.

### Variables

| Variable | Description | Default |
|----------|-------------|---------|
| `DEPLOYMENT` | Path to deployment dir (required for tofu-* targets) | — |
| `ENVIRONMENT` | Target environment | `dev` |
| `CONTAINER_RUNTIME` | Container runtime | `docker` |
| `IMAGE_TAG` | Image tag for shared step | from `pyproject.toml` |
| `PIP_VERSION` | pip pin used by `unit-tests-shared` | `24.2` |
| `POETRY_VERSION` | Poetry pin used by `unit-tests-shared` | `1.8.3` |

### Targets

| Target | Description |
|--------|-------------|
| `all` | Steady-state setup: deploy account-setup + deploy shared image |
| `deploy-account-setup` | Deploy the account-setup infrastructure |
| `deploy-shared` | Full shared image pipeline: test → build → push → update SSM |
| `tofu-init` | Initialize OpenTofu (requires `DEPLOYMENT`) |
| `tofu-plan` | Plan OpenTofu changes (requires `DEPLOYMENT`) |
| `tofu-apply` | Apply OpenTofu changes (requires `DEPLOYMENT`) |
| `tofu-destroy` | Destroy OpenTofu resources (requires `DEPLOYMENT`) |
| `unit-tests-shared` | Run unit tests for the shared step |
| `build-shared` | Build the shared container image |
| `push-shared` | Push the shared image to ECR |
| `update-parameter-store-shared` | Update SSM parameter with shared image tag |

### Examples

```bash
# Steady state — deploy everything
make all

# Just deploy infrastructure
make tofu-apply DEPLOYMENT=account-setup

# Just rebuild and push the shared image
make deploy-shared

# Plan only (review before apply)
make tofu-plan DEPLOYMENT=account-setup

# Use finch instead of docker
make all CONTAINER_RUNTIME=finch
```

### Deployment order (steady state)

1. **account-setup** — VPC, subnets, NAT Gateway, flow logs, state bucket config, shared ECR repos
2. **shared image** — build and push `copy-intermediate-to-output` to ECR

For a fresh account the state bucket does not yet exist. Follow the two-pass procedure in [Quick start (first time — fresh account)](#quick-start-first-time--fresh-account) above.

After account setup, deploy pipelines from the repository root:

```bash
cd ../..
make tofu-apply DEPLOYMENT=end-to-end
```
