<!-- Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved. SPDX-License-Identifier: MIT-0 -->

# Troubleshooting

Known issues and workarounds for the simple-workflow-generator repository. Referenced from the root [README](README.md), the [modules index](infra/README.md), and the [examples index](examples/README.md).

## Table of contents

- [Bootstrap and state bucket](#bootstrap-and-state-bucket)
- [OpenTofu apply / destroy](#opentofu-apply--destroy)
- [Container images and ECR](#container-images-and-ecr)
- [Pipeline execution](#pipeline-execution)
- [Local tooling](#local-tooling)
- [Pre-commit and CI checks](#pre-commit-and-ci-checks)

---

## Bootstrap and state bucket

### `tofu init` fails with `NoSuchBucket` or `AccessDenied` on the backend

The `account-setup` deployment provisions its own state backend, so on a
fresh account the S3 bucket referenced by `backend "s3" {}` does not exist
yet. Use the **two-pass** bootstrap:

1. In `infra/deployments/account-setup/terraform.tf`, ensure `backend "s3" {}` is **commented out** (ships that way).
2. `make deploy-account-setup` — applies with local state and creates the bucket + KMS CMK.
3. **Uncomment** `backend "s3" {}` in `terraform.tf`.
4. `make deploy-account-setup` again — OpenTofu prompts to migrate the local state file into the S3 bucket. Answer **yes**.

From this point on, `tofu init` reads and writes state remotely. If the account was already bootstrapped from a different workstation, confirm your caller identity has read/write access to the state bucket and its KMS key (see the [account-setup README](infra/deployments/account-setup/README.md)).

### `tofu init` complains that the backend changed

Expected during step 4 of the two-pass bootstrap above (`backend configuration changed` prompt). Answering **yes** to the migration prompt copies the local `terraform.tfstate` into the S3 bucket and is safe. If you already have remote state and see this unexpectedly, someone has modified `terraform.tf` — `git diff account-setup/terraform.tf` to check.

---

## OpenTofu apply / destroy

### `tofu destroy` fails with `RepositoryNotEmpty` on an ECR repository

The `central-ecr` module creates repositories with `force_delete = false` by default, so a repository that still contains images blocks `tofu destroy`. (The `pipeline` module defaults `ecr_force_delete = true`, and every example `inputs.tfvars.example` sets it to `true` — so per-pipeline repos usually drop cleanly.) To let `tofu destroy` drop repositories that still contain images (dev accounts only), set `ecr_force_delete = true` in `env/<env>/inputs.tfvars` before destroying.

### `tofu destroy` leaves S3 buckets behind

Buckets created by `pipeline-initialization` are not force-destroyed by default. Empty the bucket first (`aws s3 rm --recursive s3://<bucket>` and remove all versions), or set `s3_force_destroy = true` on the module input if you truly want automated teardown.

### `InvalidBucketName` on `tofu apply`

Pipeline names are used as S3 prefixes and must follow [S3 bucket naming rules](https://docs.aws.amazon.com/AmazonS3/latest/userguide/bucketnamingrules.html): lowercase letters, digits, and hyphens only. Rename the pipeline directory and update `pipeline_name` in `pipeline.yaml` if you used underscores or uppercase characters.

### `ProviderVersionConflict` after switching branches

Delete the per-deployment `.terraform/` cache and re-run `make tofu-init` (the target already passes `--reconfigure --upgrade`, but a stale lockfile can survive). If the conflict is on the AWS provider major, ensure your local `tofu` is at the version pinned in each module's `terraform` block (`>= 1.8`).

### Duplicate `checkov` findings after adding a Makefile

Checkov scans the plan JSON produced by `make checkov-check`. When the plan artifact is regenerated with modified Makefile paths, previously-suppressed findings may resurface because the resource keys change. Re-run `make checkov-check DEPLOYMENT=<pipeline>` and, if the finding is genuinely a false positive, add a `checkov:skip=<CHECK_ID>: <justification>` comment on the resource in `.tf` rather than editing `.checkov.yaml`.

---

## Container images and ECR

### `push-image-local` fails with `denied: User is not authorized to perform: ecr:InitiateLayerUpload`

The caller identity you assumed does not have push permissions on the target repository. Authenticate with credentials that grant `ecr:*` on the target repos. See [`infra/deployments/account-setup/README.md`](infra/deployments/account-setup/README.md).

### `check-image-version` fails with `Image tag <version> exists in ECR`

The `version` field in the step's `pyproject.toml` already has a matching image in ECR. Bump the version before rebuilding — see [`code/README.md`](code/README.md) for the versioning contract. This is a deliberate guard against silent overwrites.

### Runtime `pull access denied` from Batch / Lambda

Confirm the SSM parameter `/pipelines/<pipeline>-<env>-<step>` (or `/pipelines/shared-<name>-ecr-url` for shared images) points at the tag that was actually pushed. Running `make update-parameter-store DIR=<pipeline>/code/<step> IMAGE_TAG=<tag>` after the push realigns SSM with the image tag.

### `docker` is not installed on the runner

The default `CONTAINER_RUNTIME` is `docker`. To use Finch or Podman, set `CONTAINER_RUNTIME=finch` (or `podman`) on the `make` command line — e.g. `make deploy DEPLOYMENT=my-pipeline CONTAINER_RUNTIME=finch`.

---

## Pipeline execution

### Step Functions execution fails immediately on `Parallel-Block-Initialization`

The Lambda relies on `INTERMEDIATE_BUCKET` being present in its environment. If you have hand-edited the module or the state was partially destroyed, apply the pipeline again — OpenTofu re-injects the variable from `pipeline-initialization` outputs. See [`infra/modules/pipeline/lambdas/README.md`](infra/modules/pipeline/lambdas/README.md#configuration).

### `MAP_ITEM` is a single string when I expected a list

`MAP_ITEM` is always the current iteration's element, not the whole array. If a single value was passed via `inputs.value` (custom mode), it is wrapped in a one-element list and one iteration runs. Pass an array to see fan-out.

---

## Local tooling

### `poetry install` fails with `The current project's Python requirement (...) is not compatible with your Python version`

The step `pyproject.toml` files in `examples/my-pipeline/` currently target `>=3.10,<3.14` and `>=3.10,<4.0`. Install Python 3.12 (matches `PYTHON` in `infra/deployments/Makefile`), or use `poetry env use python3.12` before running the make targets.

### `make unit-tests` regenerates `poetry.lock` and my working tree is dirty

`poetry install` refreshes the lock file if it detects a resolver difference. Two options:

1. Commit the regenerated `poetry.lock` — it is the intended artifact.
2. Restore it afterward if the change was incidental: `git checkout -- <step>/poetry.lock`. (`poetry install` respects the committed lock and only re-resolves when `pyproject.toml` no longer matches it — there is no `--no-update` flag on `poetry install`.)

Do not delete `poetry.lock` — that produces non-reproducible test runs.

### `check-jsonschema` complains that `pipeline.yaml` uses an unknown field

The schema in `infra/modules/pipeline/schemas/pipeline.schema.json` is the source of truth. New fields must be added there first, then to the module `variables.tf`. If you legitimately need a field the schema does not accept, extend the schema in a separate commit and re-run pre-commit.

---

## Pre-commit and CI checks

### `pre-commit install` conflicts with an existing global hook

Bypass your global `~/.gitconfig` for the install command only:

```bash
GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null pre-commit install
```

This installs the repo-local hooks under `.git/hooks/` without inheriting whatever hookspath your global config points at.

### `terraform_docs` rewrites the README and blocks the commit

Expected on first run — the hook injects the `BEGIN_TF_DOCS ... END_TF_DOCS` block from `variables.tf` / `outputs.tf`. Stage the updated README and commit again.

### `bandit` fails on a new Python file

Bandit findings are hard failures. Either fix the finding, or add `# nosec B<id> - <justification>` on the specific line. Do not disable Bandit globally.

### `tflint` warns about unused variables after removing a resource

TFLint flags declared variables that are no longer referenced. Delete the variable from `variables.tf` and the corresponding entry from `env/<env>/inputs.tfvars.example`.
