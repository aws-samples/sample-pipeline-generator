<!-- Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved. SPDX-License-Identifier: MIT-0 -->

# Copy intermediate to output

Batch job container that syncs data from the intermediate S3 bucket to the output S3 bucket.

## Purpose

This container is used in data pipelines to copy processed data from intermediate storage to the final output data bucket. It supports copying data from multiple pipeline steps in a single execution.

## Environment variables

Required environment variables:

- `INTERMEDIATE_BUCKET`: Source S3 bucket name
- `OUTPUT_BUCKET`: Destination S3 bucket name
- `SFN_EXECUTION_ID`: Step Functions execution ID (used as the base path)
- `SOURCE_STEP_NAMES`: Comma-separated list of step names to copy (e.g., "step1,step2,step3")

## Usage

The container is automatically invoked by AWS Batch as part of the pipeline execution. It syncs data from:

```
s3://{INTERMEDIATE_BUCKET}/{SFN_EXECUTION_ID}/{STEP_NAME}/
```

to:

```
s3://{OUTPUT_BUCKET}/{SFN_EXECUTION_ID}/{STEP_NAME}/
```

## IAM permissions

The Batch job role requires:
- `s3:ListBucket` on both buckets
- `s3:GetObject` on intermediate bucket
- `s3:PutObject` on output bucket
- KMS permissions if buckets are encrypted

## Development

Install dependencies:
```bash
poetry install
```

Run tests:
```bash
poetry run pytest
```
