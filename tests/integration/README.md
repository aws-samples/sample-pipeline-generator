<!-- Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved. SPDX-License-Identifier: MIT-0 -->

# Integration tests

End-to-end tests that execute pipelines via Step Functions and verify the results.

## Prerequisites

- AWS credentials configured with access to the target account
- Pipelines deployed via `examples/` (end-to-end, s3-parallel-first, etc.)
- Python dependencies installed: `pip install -r tests/requirements.txt`

## Running

From the repository root, the top-level `Makefile` installs `requirements.txt` into a pinned
virtualenv and derives each ARN from `AWS_ACCOUNT_ID` / `AWS_REGION` / `ENVIRONMENT`:

```bash
make integration-tests                              # all four suites
make integration-tests PIPELINE=end-to-end          # one suite
make integration-tests PIPELINE=end-to-end \
  SFN_ARN=arn:aws:states:us-east-1:123456789012:stateMachine:end-to-end-dev
```

`SFN_ARN` overrides the derived ARN and requires `PIPELINE` so the matching suite is selected.

To invoke `pytest` directly instead, each test file targets a specific pipeline and requires its Step Function ARN:

```bash
# Integration test (full pipeline: ingest → validate → split → parallel → aggregate → publish)
pytest tests/integration/test_end_to_end_pipeline.py \
  --sfn-arn="arn:aws:states:us-east-1:<account_id>:stateMachine:end-to-end-dev" \
  -v -s --log-cli-level=INFO

# S3 parallel-first (parallel block as first step)
pytest tests/integration/test_s3_parallel_first_pipeline.py \
  --sfn-arn="arn:aws:states:us-east-1:<account_id>:stateMachine:s3-parallel-first-dev" \
  -v -s --log-cli-level=INFO

# S3 parallel-middle (lambda prepares data, then parallel discovers)
pytest tests/integration/test_s3_parallel_middle_pipeline.py \
  --sfn-arn="arn:aws:states:us-east-1:<account_id>:stateMachine:s3-parallel-middle-dev" \
  -v -s --log-cli-level=INFO

# S3 parallel-from-step (from_step targeting a non-adjacent step)
pytest tests/integration/test_s3_parallel_from_step_pipeline.py \
  --sfn-arn="arn:aws:states:us-east-1:<account_id>:stateMachine:s3-parallel-from-step-dev" \
  -v -s --log-cli-level=INFO
```

When invoking `pytest` directly, run the tests one at a time, since each needs a different ARN.
`make integration-tests` handles the per-suite ARN automatically.

## Test files

| File | Pipeline | Description |
|------|----------|-------------|
| `test_end_to_end_pipeline.py` | end-to-end | Full pipeline: `ingest_raw_data` (batch) → `validate_ingestion` (lambda) → `split_workload` (lambda) → `fan_out_processing` (parallel: `transform_chunk` + `score_chunk`) → `aggregate_results` (batch, copy_to_target) → `publish_report` (lambda) |
| `test_s3_parallel_first_pipeline.py` | s3-parallel-first | Parallel block is the first step; discovers directories on the source bucket via `root_prefix` |
| `test_s3_parallel_middle_pipeline.py` | s3-parallel-middle | `prepare_data` lambda writes subdirectories, then parallel block discovers them on intermediate bucket |
| `test_s3_parallel_from_step_pipeline.py` | s3-parallel-from-step | Tests `from_step` option: `prepare_data` → `discover_sources` → parallel with `from_step: prepare_data` |

## How each test works

1. **Setup** — Uploads test data to the appropriate bucket (source bucket for `end-to-end` and `s3-parallel-first`; self-contained for the others where lambdas create the data)
2. **Execute** — Starts the Step Function with the correct payload
3. **Poll** — Waits for execution to complete (up to 15 minutes for complex pipelines)
4. **Verify** — Asserts `SUCCEEDED` status and checks expected outputs exist in intermediate/output buckets
5. **Cleanup** — Removes test data from buckets (runs even on failure)

## Bucket naming convention

Bucket names are derived from the SFN ARN automatically:

```
<pipeline_name>-<env>-<bucket_type>-<account_id>
```

For example, with ARN `arn:aws:states:us-east-1:123456789012:stateMachine:end-to-end-dev`:
- Source bucket: `end-to-end-dev-source-123456789012`
- Intermediate bucket: `end-to-end-dev-intermediate-123456789012`
- Output bucket: `end-to-end-dev-output-123456789012`

No additional CLI arguments are needed beyond `--sfn-arn`; the AWS region is also derived from the ARN, so the boto3 clients always target the region where the state machine is deployed.

## CI/CD

This repository ships no CI/CD workflows. If you add GitHub Actions, run the integration tests as a matrix job after infrastructure deployment, capturing each pipeline's SFN ARN from the OpenTofu outputs and passing it to the corresponding test file.
