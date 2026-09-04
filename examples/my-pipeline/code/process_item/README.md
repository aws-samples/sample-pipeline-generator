# my-pipeline - process_item

AWS Lambda step that processes a single item from an S3 discovery fan-out (Step Functions parallel `Map`). Receives the discovered S3 prefix as `MAP_ITEM` and writes a marker file to the intermediate bucket to confirm processing.

## What it does

1. Reads `STEP_NAME` and `INTERMEDIATE_BUCKET` from environment variables (set by the pipeline).
2. Reads `SFN_EXECUTION_ID` and `MAP_ITEM` from the Step Functions event payload.
3. Logs any `STEP_*` keys (previous step results) and the optional `EXECUTION_INPUT` for traceability.
4. Writes a JSON marker (`{"source": <map_item>, "status": "processed"}`) to the intermediate bucket under `<execution_id>/<step_name>/<map_item-suffix>processed.json`.
5. Returns `{"status": "success", "source": <map_item>}` to Step Functions.

The output key is derived by stripping the first two path segments from `MAP_ITEM` (which already contains `<exec_id>/<source_step>/...`) and prefixing the current `<step_name>` so paths do not duplicate.

Any failure raises an exception, which propagates to Step Functions and fails the Map iteration.

## Environment Variables

| Variable | Source | Description |
|---|---|---|
| `STEP_NAME` | Lambda environment | Name of this pipeline step |
| `INTERMEDIATE_BUCKET` | Lambda environment | Bucket where the marker file is written |
| `PIPELINE_NAME` | Lambda environment (optional) | Used as a Powertools log key; defaults to `unknown` |

## Event Payload

| Field | Required | Description |
|---|---|---|
| `SFN_EXECUTION_ID` | yes | Step Functions execution name (used as the top-level S3 prefix) |
| `MAP_ITEM` | yes | The S3 prefix this iteration is processing |
| `EXECUTION_INPUT` | no | The original SFN execution input (logged only) |
| `STEP_*` | no | Outputs of previous steps (logged only) |

## Tests

```bash
poetry install --with test
poetry run pytest -q
```

Tests use `unittest.mock.patch` on the module-level S3 client and `monkeypatch` for env vars; no real AWS calls.
