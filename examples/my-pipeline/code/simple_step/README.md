# my-pipeline - simple_step

AWS Batch job that demonstrates S3 access and Step Functions parameter passing in `my-pipeline`. It reads from a source bucket, writes a result file to the intermediate bucket, and verifies the round-trip.

## What it does

1. Reads runtime parameters from environment variables (set by Step Functions on `batch:submitJob.sync`).
2. Lists and reads every object under `s3://$SOURCE_BUCKET/<root_prefix>`, where `<root_prefix>` comes from the execution input (`inputs.root_prefix`, empty when absent).
3. Writes a `result.json` summary to `s3://$INTERMEDIATE_BUCKET/<execution_id>/<step_name>/result1/result.json` and `.../result2/result.json` — two prefixes for the downstream fan-out to discover.
4. Reads each file back and asserts the content matches what was written.

Any failure raises an exception; the non-zero exit propagates to Step Functions through `batch:submitJob.sync` and fails the run.

## Environment Variables

| Variable | Required | Source | Description |
|---|---|---|---|
| `SFN_EXECUTION_ID` | yes (strict, read at import) | Step Functions container override | Current execution name; used as the top-level S3 prefix |
| `INTERMEDIATE_BUCKET` | yes (strict, read in `main()`) | Batch job definition | Bucket where the result files are written |
| `SOURCE_BUCKET` | yes (strict, read in `main()`) | Batch job definition | Source bucket to read from |
| `EXECUTION_INPUT` | no (defaults to `{}`) | Step Functions container override | Raw execution input JSON; `inputs.root_prefix` selects the S3 prefix to read (bucket root when absent) |
| `STEP_NAME` | no (defaults to `unknown`) | Batch job definition | Name of this pipeline step; used as a Powertools log key and in the output S3 key |
| `PIPELINE_NAME` | no (defaults to `unknown`) | Batch job definition | Pipeline name; used as a Powertools log key for log aggregation |

`SFN_EXECUTION_ID` is read at module import time. If it is missing, the container fails before `main()` runs — by design, so the container fails fast in production.

## Tests

```bash
poetry install --with test
poetry run pytest -q
```

The tests mock the S3 client — no AWS credentials required.

## Build & Push

From the repository root, using the top-level `Makefile`:

```bash
# Build the image locally
make build-image DIR=my-pipeline/code/simple_step IMAGE_TAG=1.1.0

# Build, log into ECR, and push (also tags as :latest)
make push-image-local DIR=my-pipeline/code/simple_step IMAGE_TAG=1.1.0

# Verify a tag isn't already taken before bumping the pyproject.toml version
make check-image-version DIR=my-pipeline/code/simple_step IMAGE_TAG=1.1.0

# Update the SSM parameter so the pipeline picks up the new tag
make update-parameter-store DIR=my-pipeline/code/simple_step IMAGE_TAG=1.1.0
```

When CI/CD workflows are added, the same targets are intended to run automatically; until then, invoke them locally as shown above.
