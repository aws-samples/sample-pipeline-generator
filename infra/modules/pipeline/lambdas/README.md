<!-- Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved. SPDX-License-Identifier: MIT-0 -->

# Pipeline Lambda functions

## Features

- **Parallel Block Initialization Function**: Resolves inputs (S3 discovery or custom values) for dynamic parallel block processing
- Integrated with AWS Lambda Powertools for structured logging
- Distributed tracing via AWS Distro for OpenTelemetry (ADOT)
- Comprehensive error handling and validation

## Lambda functions

### Parallel Block Initialization function

Resolves inputs for a parallel block based on type: discovers S3 directories or passes through custom values. Automatically inserted before each parallel block in the pipeline.

The intermediate bucket is read from the `INTERMEDIATE_BUCKET` environment
variable (set by OpenTofu). If the variable is missing the Lambda fails
immediately with a `KeyError`.

**Input Event (S3 discovery — first step in pipeline):**

When the parallel block is the first step, the source bucket is used (injected
by OpenTofu). Only `root_prefix` comes from the execution payload.

```json
{
  "inputs": {
    "type": "s3",
    "root_prefix": "input/data/"
  },
  "source_bucket": "my-source-bucket",
  "execution_id": "exec-123",
  "intermediate_bucket": "my-intermediate-bucket"
}
```

**Input Event (S3 discovery — previous compute step exists):**

When there is a preceding compute step, the intermediate bucket is used
automatically at `<execution_id>/<previous_step>/`. The `previous_step` field
is injected by OpenTofu.

```json
{
  "inputs": {
    "type": "s3"
  },
  "execution_id": "exec-123",
  "intermediate_bucket": "my-intermediate-bucket",
  "previous_step": "ingest_raw_data"
}
```

**Input Event (S3 discovery with explicit `from_step`):**

When `from_step` is specified, discovery targets the intermediate bucket at
`<execution_id>/<from_step>/`. An optional `root_prefix` can be provided to
discover a subdirectory within that step's output.

Without `root_prefix` (discovers directly under the from_step output):
```json
{
  "inputs": {
    "type": "s3",
    "from_step": "step_2"
  },
  "execution_id": "exec-123",
  "intermediate_bucket": "my-intermediate-bucket"
}
```
→ Discovers directories under: `exec-123/step_2/`

With `root_prefix` (discovers a subdirectory within the from_step output):
```json
{
  "inputs": {
    "type": "s3",
    "from_step": "step_2",
    "root_prefix": "validated/subset"
  },
  "execution_id": "exec-123",
  "intermediate_bucket": "my-intermediate-bucket"
}
```
→ Discovers directories under: `exec-123/step_2/validated/subset/`

**Bucket resolution order (S3 type):**

| Scenario | Bucket | Prefix |
|---|---|---|
| `from_step` is set (no `root_prefix`) | `intermediate_bucket` | `<execution_id>/<from_step>/` |
| `from_step` is set (with `root_prefix`) | `intermediate_bucket` | `<execution_id>/<from_step>/<root_prefix>/` |
| `previous_step` is set (no `from_step`) | `intermediate_bucket` | `<execution_id>/<previous_step>/` |
| First step (neither) | `source_bucket` | `root_prefix` from execution payload |

When `from_step` is used, the optional `root_prefix` is appended *after* the
from_step directory. This allows targeting a specific subdirectory within a
step's output — for example, if `step_2` writes to both `validated/` and
`rejected/` subdirectories, you can fan out over just the validated data:

```json
{
  "inputs": {
    "type": "s3",
    "from_step": "step_2",
    "root_prefix": "validated"
  }
}
```

The bucket is never user-overridable at execution time — it is always resolved
by OpenTofu based on the pipeline structure.

**Input Event (Custom values — passthrough from execution payload):**

Values can be anything your batch containers know how to handle — S3 paths, URLs, database URIs, arbitrary identifiers, etc. The function performs a simple passthrough.

```json
{
  "inputs": {
    "type": "custom",
    "value": ["https://api.example.com/dataset/1", "some-identifier", "https://other-endpoint.example.com"]
  },
  "execution_id": "exec-123",
  "intermediate_bucket": "my-intermediate-bucket"
}
```

**Input Event (Custom values from a previous step's output):**

```json
{
  "inputs": {
    "type": "custom",
    "from_step": "split_workload",
    "field": "chunks"
  },
  "execution_id": "exec-123",
  "intermediate_bucket": "my-intermediate-bucket",
  "from_step_result": {
    "chunks": ["chunk-1", "chunk-2", "chunk-3"]
  }
}
```

If a single value is provided instead of a list, it is automatically wrapped in one-element list.

**Output (S3 discovery):**
```json
{
  "statusCode": 200,
  "source_paths": ["input/data/dir1/", "input/data/dir2/"],
  "resolved_bucket": "my-pipeline-bucket"
}
```

**Output (Custom values — passthrough):**

```json
{
  "statusCode": 200,
  "source_paths": ["https://api.example.com/dataset/1", "some-identifier", "https://other-endpoint.example.com"],
  "resolved_bucket": null
}
```

## Installation

```bash
# Install poetry if not already installed
pip install poetry==2.4.1

# Install dependencies
cd lambdas
poetry install
```

## Usage

### Running tests

```bash
# From the pipeline module directory
bash run_tests.sh

# Or directly with poetry
cd lambdas
poetry run pytest
```

### Test coverage

Current test coverage: **100%**

Tests include:
- Unit tests with mocked AWS services (moto)
- Error handling scenarios
- Edge cases (empty directories, missing buckets)
- S3 operations validation

## Development

### Project structure

```
lambdas/
├── parallel_block_initialization/
│   └── index.py              # Parallel block initialization handler
├── tests/
│   └── test_parallel_block_initialization.py
├── pyproject.toml            # Poetry configuration
├── poetry.lock               # Poetry lock file
├── .gitignore                # Git ignore patterns
└── README.md                 # This file
```

### Adding new Lambda functions

1. Create a new directory under `lambdas/`
2. Add `index.py` with a `handler` function
3. Create corresponding test file in `tests/`
4. Update `pyproject.toml` if new dependencies are needed
5. Run tests to ensure coverage

### Code standards

- Use AWS Lambda Powertools for logging
- Tracing is handled automatically by the ADOT Lambda Layer
- Include comprehensive error handling
- Write unit tests with >90% coverage
- Use type hints where applicable
- Follow PEP 8 style guidelines

### Testing guidelines

- Mock AWS services using `moto` and `unittest.mock`
- Test both success and error scenarios
- Validate input/output formats
- Check error messages and status codes
- Ensure proper resource cleanup

## Dependencies

Managed via Poetry in `pyproject.toml`:

- **boto3**: AWS SDK for Python
- **aws-lambda-powertools**: Structured logging
- **pytest**: Testing framework
- **moto**: AWS service mocking
- **pytest-cov**: Coverage reporting

## ADOT Lambda layer

These Lambda functions use the AWS Distro for OpenTelemetry (ADOT) Python layer for distributed tracing. Layer ARNs are defined in `../service_lambdas.tf` as a per-region map (`adot_python_layer_arns`).

To update the ADOT layer version:

1. Check the latest versions at: https://aws-otel.github.io/docs/getting-started/lambda
2. Update the `adot_python_layer_arns` map in `../service_lambdas.tf`
3. No further action needed for step Lambdas — `../lambda_steps.tf` reuses the same `local.lambda_layers` value, so the change propagates automatically
4. From `examples/`, run `make tofu-plan DEPLOYMENT=end-to-end` to verify the change

## Configuration

Lambda functions are configured via environment variables and event parameters:

- `INTERMEDIATE_BUCKET` **(required)**: Name of the pipeline's intermediate S3 bucket. Injected by OpenTofu from `service_lambdas.tf`. If missing, the handler raises `KeyError` immediately — there is no silent fallback.
- `OTEL_SERVICE_NAME`: OpenTelemetry service name, set by OpenTofu (the Powertools logger service name is hard-coded to `parallel_block_initialization` in the handler)
- `LOG_LEVEL`: Logging level (default: INFO)
- `AWS_LAMBDA_EXEC_WRAPPER`: Set to `/opt/otel-instrument` by OpenTofu to enable ADOT auto-instrumentation

## Deployment

These Lambda functions are deployed as part of the pipeline OpenTofu module. See the main project README for deployment instructions.

## Troubleshooting

### Common issues

**Import errors in tests:**
- Ensure `sys.path` is correctly set in test files
- Check that the module structure matches import statements

**Moto mocking issues:**
- Use `@mock_aws` decorator for AWS service mocking
- Reload modules within test functions if needed
- Mock module-level boto3 clients using `unittest.mock.patch`

**Coverage warnings:**
- Ignore coverage warnings for test files and cache directories
- Configure coverage exclusions in `pyproject.toml`

## Contributing

1. Write tests for new functionality
2. Ensure all tests pass: `bash ../run_tests.sh`
3. Maintain >90% test coverage
4. Update this README with new features
5. Follow existing code patterns and standards
