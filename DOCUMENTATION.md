<!-- Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved. SPDX-License-Identifier: MIT-0 -->

# Documentation index

Quick jump table by intent. For the primary index and repository overview, see [`README.md`](README.md).

## Where to find what

| I want to... | Go to |
|---|---|
| Understand the project and how it is structured | [`README.md`](README.md) |
| Define a new pipeline (YAML syntax) | [`infra/modules/pipeline/schemas/README.md`](infra/modules/pipeline/schemas/README.md) |
| See what execution payload to pass when starting a pipeline | [`infra/modules/pipeline/schemas/README.md`](infra/modules/pipeline/schemas/README.md) — [S3 discovery modes](infra/modules/pipeline/schemas/README.md#s3-discovery-modes) and [Custom value modes](infra/modules/pipeline/schemas/README.md#custom-value-modes) |
| Know what environment variables my step code receives | [`infra/modules/pipeline/step_functions/README.md`](infra/modules/pipeline/step_functions/README.md) |
| Understand how runtime parameters and execution input work | [`infra/modules/pipeline/step_functions/README.md`](infra/modules/pipeline/step_functions/README.md#runtime-parameters) |
| Write a Lambda step handler | [`infra/modules/pipeline/step_functions/README.md`](infra/modules/pipeline/step_functions/README.md#lambda-step) |
| Write a Batch step container | [`infra/modules/pipeline/step_functions/README.md`](infra/modules/pipeline/step_functions/README.md#batch-step) |
| Handle data inside a parallel block | [`infra/modules/pipeline/step_functions/README.md`](infra/modules/pipeline/step_functions/README.md#parallel-block) |
| See how the pipeline module works (architecture, features, OpenTofu usage) | [`infra/modules/pipeline/README.md`](infra/modules/pipeline/README.md) |
| Set up structured logging in step code | [`infra/modules/pipeline/README.md`](infra/modules/pipeline/README.md#structured-logging--log-aggregation) |
| Add custom egress rules for pipeline compute (e.g., intranet access) | [`infra/modules/pipeline/README.md`](infra/modules/pipeline/README.md#compute-security-groups-sg_compute_additional) |
| Query pipeline logs in CloudWatch (saved queries, CLI examples) | [`infra/modules/pipeline/README.md`](infra/modules/pipeline/README.md#running-queries-from-the-cli) |
| Configure S3 buckets, SSM parameters, or secrets | [`infra/modules/pipeline-initialization/README.md`](infra/modules/pipeline-initialization/README.md) |
| Provision shared ECR repositories | [`infra/modules/central-ecr/README.md`](infra/modules/central-ecr/README.md) |
| Bootstrap a new AWS account | [`infra/deployments/account-setup/README.md`](infra/deployments/account-setup/README.md) |
| Use the account-setup Makefile (bootstrap, deploy shared image) | [`infra/deployments/README.md`](infra/deployments/README.md) |
| Use the top-level Makefile (per-pipeline build / test / deploy, quality gates) | [`README.md`](README.md#quality-gates) · [`examples/README.md`](examples/README.md) |
| Copy a template pipeline to start a new use case | [`examples/my-pipeline/README.md`](examples/my-pipeline/README.md) |
| Study every feature in one place | [`examples/complex-example/README.md`](examples/complex-example/README.md) |
| Run integration tests locally | [`tests/integration/README.md`](tests/integration/README.md) |
| Update ADOT Lambda layer versions | [`infra/README.md`](infra/README.md#adot-lambda-layer-versions) |
| Understand how `pyproject.toml` versions relate to ECR image tags | [`code/README.md`](code/README.md#image-versioning--pyprojecttoml-and-ecr-tags) |
| Troubleshoot a known issue | [`TROUBLESHOOTING.md`](TROUBLESHOOTING.md) |

## Structure

```
README.md                         # Primary entry point — architecture, quickstart
TROUBLESHOOTING.md                # Repo-wide known issues
DOCUMENTATION.md                  # This file — flat lookup table

infra/README.md                   # Platform overview
├── deployments/README.md         # infra/deployments/Makefile
│   └── account-setup/README.md
└── modules/
    ├── pipeline/README.md
    │   ├── schemas/README.md
    │   ├── step_functions/README.md
    │   └── lambdas/README.md
    ├── pipeline-initialization/README.md
    ├── pipeline-account-bootstrap/README.md
    ├── central-ecr/README.md
    └── lambda-alarms/README.md

examples/README.md                # Makefile & scaffold.py
├── my-pipeline/README.md
├── complex-example/README.md
├── end-to-end/README.md
├── s3-parallel-first/README.md
├── s3-parallel-middle/README.md
└── s3-parallel-from-step/README.md

code/README.md
└── shared/copy-intermediate-to-output/README.md

tests/integration/README.md
```
