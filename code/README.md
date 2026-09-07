<!-- Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved. SPDX-License-Identifier: MIT-0 -->

# Code

Shared step implementations used across pipelines.

## Directory structure

```
code/
└── shared/
    └── copy-intermediate-to-output/  # Shared across all pipelines
```

Pipeline-specific step code lives under each example's `code/` directory (e.g. `examples/end-to-end/code/ingest_raw_data/`).

## Step directory conventions

Each step directory must contain:

| File | Required | Purpose |
|------|----------|---------|
| `pyproject.toml` | **yes (batch)** | Poetry project config — defines the step name, **version**, and dependencies |
| `Dockerfile` | yes (batch) | Container image definition |
| `main.py` | yes (lambda) | Lambda handler (`handler(event, context)`) |
| `tests/` | recommended | Unit tests (`pytest`) |

## Image versioning — pyproject.toml and ECR tags

> [!IMPORTANT]
> The `version` field in `pyproject.toml` is the **source of truth** for the Docker image tag pushed to ECR.

The Make targets read the version directly from `pyproject.toml`:

```
pyproject.toml version = "2.0.2"  →  ECR tag: 2.0.2
```

**How it works:**

1. `make deploy-image` extracts the version: `grep '^version' pyproject.toml`
2. `make check-image-version` fails if that tag already exists in ECR (prevents overwriting an existing image)
3. The image is built and pushed with that version as the ECR tag

**Implications:**

- To deploy a new version of a Batch step, **bump the version in `pyproject.toml`** before rebuilding
- If you don't bump the version, `check-image-version` fails with "Image tag <tag> exists in ECR repository <name>, update the version in pyproject.toml"
- The `latest` tag is always pushed alongside the versioned tag
- The SSM parameter `/pipelines/<pipeline>-<env>-<step>` is updated with the new tag so OpenTofu picks it up on next apply
- If you wire this repository into a CI/CD system, derive the tag the same way and run `make check-image-version` as a gate

**Local workflow:**

```bash
# From the repository root
make push-image-local DIR=end-to-end/code/ingest_raw_data IMAGE_TAG=2.0.3
```

When using `push-image-local`, you can pass `IMAGE_TAG` explicitly. If omitted, it is derived from the step's `pyproject.toml` version — the same way as for CI/CD.

## Shared images

Images under `code/shared/` are built and pushed via the `infra/deployments/` Makefile. Their ECR name follows the pattern `shared-<step>` instead of `<pipeline>-<env>-<step>`.

```bash
# From infra/deployments/
make deploy-shared                    # test + build + push + update SSM
make build-shared                     # just build
make push-shared                      # just push
```
