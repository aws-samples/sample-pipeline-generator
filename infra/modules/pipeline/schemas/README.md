<!-- Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved. SPDX-License-Identifier: MIT-0 -->

# Pipeline YAML schema reference

This document describes every field available in a `pipeline.yaml` definition file. The schema is enforced by [`pipeline.schema.json`](pipeline.schema.json) and validated automatically by the `check-jsonschema` pre-commit hook on every commit that touches a `pipeline.yaml` under `examples/`.

To enable in-editor validation, add this directive as the first line of your YAML:

```yaml
# yaml-language-server: $schema=../../../modules/pipeline/schemas/pipeline.schema.json
```

---

## Table of contents

- [Top-level fields](#top-level-fields)
- [Steps](#steps)
  - [Batch step](#batch-step)
  - [Lambda step](#lambda-step)
  - [Parallel step](#parallel-step)
    - [Parallel input configuration](#parallel-input-configuration)
    - [S3 discovery modes](#s3-discovery-modes)
    - [Custom value modes](#custom-value-modes)
- [Complete example](#complete-example)
- [Minimal example](#minimal-example)

---

## Top-level fields

| Field | Type | Required | Default | Description |
|-------|------|----------|---------|-------------|
| `pipeline_name` | string | **yes** | — | Unique pipeline identifier. Used in resource naming (S3, Step Functions, Batch, ECR, CloudWatch, IAM). |
| `buckets` | list of strings | no | `["intermediate"]` | S3 bucket types to create. Allowed values: `source`, `intermediate`, `output`. The `intermediate` bucket is always required. |
| `tags` | map of strings | no | `{}` | Tags applied to all pipeline resources. `Pipeline`, `Environment`, and `DeployedBy` are added automatically. |
| `pipeline_completion_emails` | list of emails | no | `[]` | Email addresses notified when the pipeline completes (success or failure). |
| `capacity_provider` | string | no | `"FARGATE"` | Batch compute capacity. `"FARGATE"` for on-demand, `"FARGATE_SPOT"` for cost-optimized spot (up to 70% cheaper, but can be interrupted). |
| `max_concurrency` | number | no | `0` | Maximum parallel iterations for the Map step. `0` means unlimited. |
| `cw_retention_days` | number | no | `365` | CloudWatch Logs retention period in days. Must be between `15` and `730` (enforced by both `check-jsonschema` and the module's OpenTofu validation). |
| `ssm_parameters` | list of strings | no | `[]` | SSM parameter names to create as placeholders at `/pipelines/<pipeline_name>-<env>/params/<name>`. Set real values outside OpenTofu. |
| `secrets` | list of objects | no | `[]` | Secrets Manager secrets to create. Each item: `{ name: "<secret_name>" }`. Created at `/pipelines/<pipeline_name>-<env>/secrets/<name>`. |
| `steps` | list of steps | **yes** | — | Ordered list of pipeline steps. At least one step is required. At most one `parallel` step is allowed. |

---

## Steps

Steps run sequentially in the order defined. Three step types are available:

| Type | Purpose | Compute |
|------|---------|---------|
| `batch` | Run a containerized job | AWS Batch on Fargate |
| `lambda` | Run a Python function | AWS Lambda (zip deployment) |
| `parallel` | Fan out over an array | Map state containing batch/lambda inner steps |

### Batch step

Runs a Docker container on AWS Batch (Fargate). The image is pulled from an ECR repository that is either auto-created by the module or externally provided.

| Field | Type | Required | Default | Description |
|-------|------|----------|---------|-------------|
| `name` | string | **yes** | — | Step identifier. Alphanumeric and underscores only. |
| `type` | `"batch"` | **yes** | — | — |
| `ram_mb` | number | no | `2048` | Container memory in MB. |
| `vcpu` | number | no | `1` | Number of vCPUs. |
| `image_tag` | string | no | `"latest"` | Docker image tag to pull from ECR. |
| `ecr_repository_url` | string | no | — | External ECR repository URL. When omitted, the module creates a dedicated repository named `<pipeline>-<env>-<step>`. |
| `runtime_parameters` | map of strings | no | `{}` | Key-value pairs set as container environment variables at deploy time. Values must be non-empty strings. |
| `copy_to_target` | boolean | no | `false` | When `true`, this step's intermediate output is copied to the output bucket after all steps complete. Requires the `output` bucket. |

```yaml
- name: ingest_raw_data
  type: batch
  ram_mb: 4096
  vcpu: 2
  image_tag: "1.2.0"
  runtime_parameters:
    SOURCE_SYSTEM: "sensor-array-north"
    INGESTION_MODE: "full"
  copy_to_target: true
```

### Lambda step

Runs a Python function deployed as a zip package. Code must live at `<lambda_steps_code_path>/<step_name>/main.py` and export a `handler(event, context)` function. AWS Lambda Powertools and ADOT layers are always included automatically.

| Field | Type | Required | Default | Description |
|-------|------|----------|---------|-------------|
| `name` | string | **yes** | — | Step identifier. Alphanumeric and underscores only. |
| `type` | `"lambda"` | **yes** | — | — |
| `lambda_timeout` | number | no | `900` | Timeout in seconds. Maximum: 900 (15 minutes). |
| `lambda_memory_size` | number | no | `2048` | Memory in MB. Maximum: 10240. |
| `lambda_ephemeral_storage` | number | no | `512` | Ephemeral `/tmp` storage in MB. Maximum: 10240. |
| `lambda_layers` | list of strings | no | `[]` | Additional Lambda layer ARNs to attach (on top of Powertools + ADOT). |
| `runtime_parameters` | map of strings | no | `{}` | Key-value pairs set as Lambda environment variables at deploy time. Values must be non-empty strings. |

```yaml
- name: validate_ingestion
  type: lambda
  lambda_timeout: 300
  lambda_memory_size: 1024
  lambda_ephemeral_storage: 1024
  lambda_layers:
    - arn:aws:lambda:us-east-1:123456789012:layer:my-lib:3
  runtime_parameters:
    VALIDATION_PROFILE: "strict"
```

### Parallel step

Fans out over an array, running inner steps concurrently for each element. Only **one** parallel step is allowed per pipeline. Inner steps can be `batch` or `lambda` (not nested `parallel`).

| Field | Type | Required | Default | Description |
|-------|------|----------|---------|-------------|
| `name` | string | **yes** | — | Step identifier. Map results stored at `$.<name>_result`. |
| `type` | `"parallel"` | **yes** | — | — |
| `input` | object | **yes** | — | How the fan-out array is resolved. See [input configuration](#parallel-input-configuration). |
| `parallel_steps` | list | **yes** | — | One or more `batch` or `lambda` steps to run inside the Map for each element. They run sequentially within each iteration. |

```yaml
- name: fan_out_processing
  type: parallel
  input:
    type: custom
    from_step: split_workload
    field: chunks
  parallel_steps:
    - name: transform_chunk
      type: batch
      ram_mb: 8192
      vcpu: 4
      runtime_parameters:
        TRANSFORM_CONFIG: "default"
    - name: score_chunk
      type: lambda
      lambda_timeout: 900
      lambda_memory_size: 3008
```

#### Parallel input configuration

The `input` object determines what the parallel block iterates over.

| Field | Type | Required | Description |
|-------|------|----------|-------------|
| `type` | `"s3"` or `"custom"` | **yes** | `"s3"` discovers S3 directories. `"custom"` uses an explicit list of values. |
| `from_step` | string | no | Name of a preceding compute step whose output provides the data. |
| `root_prefix` | string | no | S3 prefix for directory discovery (type `s3` only). |
| `field` | string | no | Dot-notation field path in a previous step's output (type `custom` with `from_step` only). |

#### S3 discovery modes

The Parallel Block Initialization Lambda discovers subdirectories under a given S3 prefix. The bucket and prefix depend on the pipeline position:

| Mode | Configuration | Bucket | Prefix |
|------|---------------|--------|--------|
| First step in pipeline | `type: s3` (no `from_step`) | Source bucket | `root_prefix` from execution payload |
| After a preceding step (implicit) | `type: s3` (no `from_step`, previous compute step exists) | Intermediate bucket | `<exec_id>/<previous_step>/` |
| Explicit `from_step` | `type: s3`, `from_step: <step>` | Intermediate bucket | `<exec_id>/<from_step>/` |
| `from_step` + `root_prefix` | `type: s3`, `from_step: <step>`, `root_prefix: <path>` | Intermediate bucket | `<exec_id>/<from_step>/<root_prefix>/` |

**Mode 1 — first step:**
```yaml
- name: fan_out
  type: parallel
  input:
    type: s3
  parallel_steps:
    - name: process_item
      type: lambda
```
Execution payload: `{ "inputs": { "type": "s3", "root_prefix": "upload1/" } }`

**Mode 2 — after a preceding step (implicit):**
```yaml
- name: prepare_data
  type: lambda

- name: fan_out
  type: parallel
  input:
    type: s3
  parallel_steps:
    - name: process_item
      type: lambda
```
Discovers: `s3://<intermediate>/<exec_id>/prepare_data/`

**Mode 3 — explicit `from_step`:**
```yaml
- name: prepare_data
  type: lambda

- name: other_step
  type: lambda

- name: fan_out
  type: parallel
  input:
    type: s3
    from_step: prepare_data
  parallel_steps:
    - name: process_item
      type: lambda
```
Discovers: `s3://<intermediate>/<exec_id>/prepare_data/` (skips `other_step`)

**Mode 4 — `from_step` with `root_prefix`:**
```yaml
- name: prepare_data
  type: lambda

- name: fan_out
  type: parallel
  input:
    type: s3
    from_step: prepare_data
    root_prefix: validated
  parallel_steps:
    - name: process_item
      type: lambda
```
Discovers: `s3://<intermediate>/<exec_id>/prepare_data/validated/`

#### Custom value modes

Custom mode passes an explicit list of values — each becomes the `MAP_ITEM` for one parallel iteration.

| Mode | Configuration | Source of the array |
|------|---------------|---------------------|
| From execution payload | `type: custom` (no `from_step`) | `inputs.value` in the execution payload |
| From a preceding step's output | `type: custom`, `from_step: <step>`, `field: <path>` | The specified field in the step's return value |

**Mode 5 — from execution payload:**
```yaml
- name: fan_out
  type: parallel
  input:
    type: custom
  parallel_steps:
    - name: process_item
      type: batch
```
Execution payload:
```json
{
  "inputs": {
    "type": "custom",
    "value": ["item-a", "item-b", "item-c"]
  }
}
```

**Mode 6 — from a preceding step's output:**
```yaml
- name: split_workload
  type: lambda

- name: fan_out
  type: parallel
  input:
    type: custom
    from_step: split_workload
    field: chunks
  parallel_steps:
    - name: transform_chunk
      type: batch
```
If `split_workload` returns `{"chunks": ["chunk-1", "chunk-2"]}`, the parallel block iterates over those values.

For nested fields, use dot-notation: `field: result.paths` reads from `{"result": {"paths": [...]}}`.

---

## Complete example

A full-featured pipeline exercising all capabilities:

```yaml
# yaml-language-server: $schema=../../../modules/pipeline/schemas/pipeline.schema.json

pipeline_name: complex-pipeline

buckets:
  - source
  - intermediate
  - output

tags:
  UseCase: production-pipeline
  Team: data-engineering

pipeline_completion_emails:
  - team@example.com

max_concurrency: 10
capacity_provider: FARGATE_SPOT
cw_retention_days: 365

ssm_parameters:
  - API_ENDPOINT
  - MODEL_VERSION

secrets:
  - name: DB_CONNECTION_STRING
  - name: EXTERNAL_API_KEY

steps:
  - name: ingest_raw_data
    type: batch
    ram_mb: 4096
    vcpu: 2
    image_tag: "2.1.0"
    runtime_parameters:
      SOURCE_SYSTEM: "sensor-array-north"
      INGESTION_MODE: "full"

  - name: validate_ingestion
    type: lambda
    lambda_timeout: 300
    lambda_memory_size: 1024
    lambda_ephemeral_storage: 1024
    runtime_parameters:
      VALIDATION_PROFILE: "strict"

  - name: split_workload
    type: lambda
    lambda_timeout: 600
    lambda_memory_size: 2048

  - name: fan_out_processing
    type: parallel
    input:
      type: custom
      from_step: split_workload
      field: chunks
    parallel_steps:
      - name: transform_chunk
        type: batch
        ram_mb: 8192
        vcpu: 4
        runtime_parameters:
          TRANSFORM_CONFIG: "default"
      - name: score_chunk
        type: lambda
        lambda_timeout: 900
        lambda_memory_size: 3008

  - name: aggregate_results
    type: batch
    ram_mb: 4096
    vcpu: 2
    copy_to_target: true

  - name: publish_report
    type: lambda
    lambda_timeout: 120
    lambda_memory_size: 512
    runtime_parameters:
      REPORT_FORMAT: "pdf"
      DISTRIBUTION_LIST: "stakeholders"
```

---

## Minimal example

The smallest valid pipeline — a single batch step with an intermediate bucket:

```yaml
# yaml-language-server: $schema=../../../modules/pipeline/schemas/pipeline.schema.json

pipeline_name: minimal

steps:
  - name: process
    type: batch
```

This creates:
- An intermediate S3 bucket
- A Batch compute environment (Fargate, on-demand)
- An ECR repository (`minimal-<env>-process`)
- A Step Functions state machine
- CloudWatch log groups (365-day retention)
- All required IAM roles and policies
