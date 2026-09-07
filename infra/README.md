<!-- Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved. SPDX-License-Identifier: MIT-0 -->

# Infrastructure

OpenTofu modules and deployments for the workflow generator platform.

## Directory structure

```
infra/
├── deployments/                         # Account-level deployments
│   ├── Makefile                         # Unified build, test, deploy commands
│   └── account-setup/                   # AWS account bootstrap (state, VPC, VPC endpoints)
└── modules/                             # Reusable OpenTofu modules
    ├── pipeline/                        # Core pipeline orchestration module
    │   ├── lambdas/                     # Internal Lambda functions (Python)
    │   ├── step_functions/              # Step Functions template generation
    │   └── schemas/                     # pipeline.yaml JSON schema
    ├── pipeline-initialization/         # S3 buckets, SSM, Secrets Manager provisioning
    ├── pipeline-account-bootstrap/      # Optional VPC endpoints for private AWS service access
    ├── central-ecr/                     # Shared ECR with cross-account policies
    └── lambda-alarms/                   # CloudWatch alarms for Lambda functions
```

## Modules

| Module | Purpose | Documentation |
|--------|---------|---------------|
| `pipeline` | Core orchestration — Step Functions state machine, Batch compute, Lambda steps, ECR, IAM, observability | [README](modules/pipeline/README.md) |
| `pipeline-initialization` | S3 buckets (with Intelligent-Tiering), SSM parameters, Secrets Manager, KMS keys | [README](modules/pipeline-initialization/README.md) |
| `pipeline-account-bootstrap` | One-time account setup: optional VPC endpoints | [README](modules/pipeline-account-bootstrap/README.md) |
| `central-ecr` | Shared ECR repositories with cross-account pull policies, KMS encryption, lifecycle rules | [README](modules/central-ecr/README.md) |
| `lambda-alarms` | CloudWatch alarms for Lambda functions (errors, throttles, duration, concurrency) | [README](modules/lambda-alarms/README.md) |

## Deployments

| Deployment | Purpose | Documentation |
|------------|---------|---------------|
| `account-setup` | Bootstrap AWS account (VPC, state bucket, IAM, shared ECR) | [README](deployments/account-setup/README.md) |

## Quick start

```bash
cd infra/deployments
make all
```

This bootstraps the state bucket, deploys the account infrastructure, and builds the shared container image. See [`deployments/README.md`](deployments/README.md) for details.

For known issues and workarounds, see the repo-wide [TROUBLESHOOTING.md](../TROUBLESHOOTING.md).

---

## ADOT Lambda layer versions

The AWS Distro for OpenTelemetry (ADOT) Python layer provides distributed tracing for all Lambda functions in the platform. The region-keyed layer ARNs live in a single `adot_python_layer_arns` map defined in `infra/modules/pipeline/service_lambdas.tf`. Both the internal pipeline Lambda (parallel block initialization) and the user-defined Lambda steps (in `lambda_steps.tf`) consume that map through the shared `local.lambda_layers` value — there is only one place to edit.

### Keeping versions up to date

1. Check the latest published layer versions at:
   https://aws-otel.github.io/docs/getting-started/lambda

2. Update the `adot_python_layer_arns` map in `infra/modules/pipeline/service_lambdas.tf` for each region. It is the single source of truth reused by both the internal Lambda and the user-defined Lambda steps.

3. From the repository root, plan a pipeline deployment via the Makefile to verify the change is picked up correctly — e.g. `make tofu-plan DEPLOYMENT=end-to-end`.

4. Test in a non-production environment first — newer layer versions may introduce breaking changes to the OpenTelemetry SDK instrumentation.

### How ADOT is used

Every Lambda function in the platform (both internal and user-defined) is configured with:

- The ADOT Python layer attached (region-specific ARN from `adot_python_layer_arns`)
- `AWS_LAMBDA_EXEC_WRAPPER = "/opt/otel-instrument"` environment variable to enable auto-instrumentation
- `OTEL_SERVICE_NAME` set to `<pipeline_name>-<environment>-<function_key>` for trace identification

This provides automatic tracing of AWS SDK calls, HTTP requests, and Lambda invocations without any code changes in step implementations.
