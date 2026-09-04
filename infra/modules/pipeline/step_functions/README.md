<!-- Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved. SPDX-License-Identifier: MIT-0 -->

# Step functions templates — step input reference

This document describes the values passed to each step type at runtime, both for
top-level sequential steps and for steps running inside a parallel block.

> **⚠️ Important: Environment variables and execution input summary**
>
> Every step in the pipeline automatically receives the following context, regardless of step type or position:
>
> | Variable | Description | Lambda access | Batch access |
> |---|---|---|---|
> | `PIPELINE_NAME` | Pipeline name (`<pipeline>-<env>`) | `os.environ["PIPELINE_NAME"]` | `os.environ["PIPELINE_NAME"]` |
> | `STEP_NAME` | Name of the current step | `os.environ["STEP_NAME"]` | `os.environ["STEP_NAME"]` |
> | `SOURCE_BUCKET` | Source S3 bucket (if configured) | `os.environ["SOURCE_BUCKET"]` | `os.environ["SOURCE_BUCKET"]` |
> | `INTERMEDIATE_BUCKET` | Intermediate S3 bucket (always present) | `os.environ["INTERMEDIATE_BUCKET"]` | `os.environ["INTERMEDIATE_BUCKET"]` |
> | `OUTPUT_BUCKET` | Output S3 bucket (if configured) | `os.environ["OUTPUT_BUCKET"]` | `os.environ["OUTPUT_BUCKET"]` |
> | `SFN_EXECUTION_ID` | Step Functions execution name | `event["SFN_EXECUTION_ID"]` | `os.environ["SFN_EXECUTION_ID"]` |
> | `EXECUTION_INPUT` | Full JSON payload used to start the execution | `event["EXECUTION_INPUT"]` (dict) | `os.environ["EXECUTION_INPUT"]` (JSON string) |
> | `STEP_<NAME>` | Result of each preceding step (auto-generated) | `event["STEP_<NAME>"]` (dict) | `os.environ["STEP_<NAME>"]` (JSON string) |
> | `MAP_ITEM` | Current array element (parallel block only) | `event["MAP_ITEM"]` (dict) | `os.environ["MAP_ITEM"]` (JSON string) |
> | `runtime_parameters` | Deploy-time key-value pairs from YAML | `os.environ["<KEY>"]` | `os.environ["<KEY>"]` |
>
> Bucket names and `runtime_parameters` are static deploy-time environment variables set by OpenTofu. All other values (`SFN_EXECUTION_ID`, `EXECUTION_INPUT`, `STEP_*`, `MAP_ITEM`) are injected dynamically by Step Functions at runtime. In Batch steps, dynamic values are JSON-serialized strings — use `json.loads()` to parse them.
>
> The table above describes the contract for **user steps** (Batch jobs and user Lambda steps). The **internal service Lambda** — `parallel_block_initialization` — receives `STEP_NAME` and `SFN_EXECUTION_ID` via the event payload instead of environment variables. See [Internal service Lambda](#internal-service-lambda) below.

## Pipeline execution flow

```
[pre-parallel sequential steps]
    ↓
Parallel-Block-Initialization  (auto-inserted before each parallel block)
    ↓
[parallel block]  ← fans out over the array resolved by the init step
    ↓
[post-parallel sequential steps]
    ↓
[copy-to-output]
    ↓
Pipeline-Completion-Notification → End
```

## Automatic result storage

Every compute step automatically stores a trimmed result at `$.<step_name>_result`
using `ResultSelector`. This keeps the state machine data lean.

- **Lambda steps** store: `{"Payload": <function return value>}`
- **Batch steps** store: `{"status": "SUCCEEDED", "job_id": "<uuid>", "exit_code": 0}`

The full raw output (all Batch metadata, SDK headers, etc.) is always available
in the Step Functions execution history for debugging — it's just not carried
forward in the state data.

The parallel block stores a static completion sentinel `{"status": "COMPLETED"}` at `$.<parallel_block_name>_result` — the per-iteration Map outputs are discarded by the block's ResultSelector.

## Automatic previous step results

Every step automatically receives the output of all preceding steps as
individual variables named `STEP_<NAME>`, where `<NAME>` is the step name
uppercased with hyphens replaced by underscores.

- **Lambda source steps** → the function's return value (extracted via `.Payload`)
- **Batch source steps** → the trimmed result object `{"status", "job_id", "exit_code"}`
- **Parallel block** → `{"status": "COMPLETED"}` (a static sentinel; the per-iteration Map outputs are discarded by the block's ResultSelector)

For example, given this pipeline:

```yaml
steps:
  - name: pre-processing    # lambda
  - name: fan-out            # parallel
  - name: aggregate          # batch
```

The `aggregate` step automatically receives:
- `STEP_PRE_PROCESSING` → the return value of the pre-processing Lambda
- `STEP_FAN_OUT` → `{"status": "COMPLETED"}` (Map block result)

No configuration needed — this happens for every step.

## Execution input

Every step receives the full Step Functions execution input (the JSON payload
used to start the execution) as `EXECUTION_INPUT`. This allows steps to access
any values passed at execution time.

- **Lambda steps** — `event["EXECUTION_INPUT"]` (a dict)
- **Batch steps** — `os.environ["EXECUTION_INPUT"]` (a JSON-serialized string)

## Buckets

Steps receive bucket names as environment variables (batch) or Lambda
environment variables (lambda), set at deploy time by OpenTofu:

- `SOURCE_BUCKET` — the source S3 bucket (if configured in the pipeline YAML)
- `INTERMEDIATE_BUCKET` — the intermediate S3 bucket (always present)
- `OUTPUT_BUCKET` — the output S3 bucket (if configured in the pipeline YAML)

## Internal service Lambda

The module deploys one service Lambda — `parallel_block_initialization` —
that is invoked from the state machine but is **not** a user step. It follows
a different convention from user code:

| Variable | User Lambda / Batch step | Service Lambda |
|---|---|---|
| `STEP_NAME` | `os.environ["STEP_NAME"]` (deploy-time env var, one per step) | `event["STEP_NAME"]` (injected per invocation by the SFN template) |
| `SFN_EXECUTION_ID` | `event["SFN_EXECUTION_ID"]` / `os.environ["SFN_EXECUTION_ID"]` | `event["SFN_EXECUTION_ID"]` |
| `INTERMEDIATE_BUCKET` | `os.environ["INTERMEDIATE_BUCKET"]` | `os.environ["INTERMEDIATE_BUCKET"]` |
| `intermediate_bucket` (lowercase) | — | `event["intermediate_bucket"]` (also passed in event for convenience) |

**Why the asymmetry:** user steps get a dedicated Batch job definition or
Lambda function per step, so OpenTofu can hard-code `STEP_NAME` as a static
environment variable. The service Lambda is deployed **once per pipeline**
and is reused by every parallel block. A static env var would be wrong
because the same function serves multiple steps — so the SFN template
injects the correct `STEP_NAME` into the event payload for each invocation.

If you add a new service Lambda that is shared across steps, follow this same
pattern: read `STEP_NAME` and `SFN_EXECUTION_ID` from the event, not from the
environment.

---

## Sequential steps (outside the parallel block)

### Lambda step

Values are passed as the Lambda **event payload** (`event` argument).

| Payload Field              | Source                                                  | Description                                                |
|----------------------------|---------------------------------------------------------|------------------------------------------------------------|
| `SFN_EXECUTION_ID`        | `$$.Execution.Name`                                    | Step Functions execution name                              |
| `STEP_<NAME>`              | `$.<step>_result.Payload` or `$.<step>_result`         | Each preceding step's result (auto-generated)              |
| `EXECUTION_INPUT`          | `$$.Execution.Input`                                   | Full execution input payload                               |

Access in code:
```python
import os

def handler(event, context):
    # Log key presence at INFO; raw values only at DEBUG (may contain caller-supplied secrets/PII)
    for key in (k for k in event.keys() if k.startswith("STEP_")):
        logger.info("Previous step result present", key=key)
        logger.debug("Previous step result value", key=key, value=event[key])
    execution_input = event.get("EXECUTION_INPUT")
    if execution_input:
        logger.info("Execution input received", keys=list(execution_input.keys()))
        logger.debug("Execution input value", execution_input=execution_input)

    event["SFN_EXECUTION_ID"]                          # execution name
    event["STEP_PRE_PROCESSING"]                        # previous lambda step's return value
    event["STEP_INGEST"]                                # previous batch step's trimmed result
    event["EXECUTION_INPUT"]                            # full execution payload

    # Runtime parameters are deploy-time environment variables
    os.environ["CUSTOM_PARAM"]                          # always the YAML value

    # Override pattern: prefer execution input over deploy-time default
    exec_input = event.get("EXECUTION_INPUT", {})
    custom_param = exec_input.get("CUSTOM_PARAM", os.environ.get("CUSTOM_PARAM", ""))
```

### Batch step

Values are passed as container **environment variables** (`os.environ`).

| Env Variable                | Source                                                              | Description                                                |
|-----------------------------|---------------------------------------------------------------------|------------------------------------------------------------|
| `SFN_EXECUTION_ID`         | `$$.Execution.Name`                                                | Step Functions execution name                              |
| `STEP_<NAME>`               | `States.JsonToString($.<step>_result[.Payload])`                   | Each preceding step's result (JSON-serialized)             |
| `EXECUTION_INPUT`           | `States.JsonToString($$.Execution.Input)`                           | Full execution input payload (JSON-serialized)             |

Access in code:
```python
import json, os

def main():
    # Log key presence at INFO; raw values only at DEBUG (may contain caller-supplied secrets/PII)
    for key in (k for k in os.environ if k.startswith("STEP_") and k != "STEP_NAME"):
        logger.info("Previous step result present", key=key)
        logger.debug("Previous step result value", key=key, value=os.environ[key])
    execution_input = os.environ.get("EXECUTION_INPUT")
    if execution_input:
        payload = json.loads(execution_input)
        logger.info("Execution input received", keys=list(payload.keys()))
        logger.debug("Execution input value", execution_input=payload)

    os.environ["SFN_EXECUTION_ID"]                                  # execution name
    json.loads(os.environ["STEP_PRE_PROCESSING"])                    # previous lambda step's return value
    json.loads(os.environ["STEP_INGEST"])                            # previous batch step's trimmed result
    json.loads(os.environ["EXECUTION_INPUT"])                        # full execution payload

    # Runtime parameters are deploy-time environment variables
    os.environ["CUSTOM_PARAM"]                                      # always the YAML value

    # Override pattern: prefer execution input over deploy-time default
    exec_input = json.loads(os.environ.get("EXECUTION_INPUT", "{}"))
    custom_param = exec_input.get("CUSTOM_PARAM", os.environ.get("CUSTOM_PARAM", ""))
```

> **Note:** `STEP_*` and `EXECUTION_INPUT` values are JSON-serialized strings.
> Use `json.loads()` to parse them.

---

## Parallel block

A parallel block (defined with `type: parallel` in the YAML) fans out over an
array produced by a previous step. It spins up one job per array element,
running the inner steps for each element concurrently.

The parallel block is configured with:
- `input.type` — `s3` for S3 directory discovery, `custom` for passthrough values
- `input.from_step` — (optional) name of a preceding step whose output provides the fan-out data
- `input.field` — (for custom with from_step) dot-notation field path in the step's output
- `input.root_prefix` — (for s3) S3 prefix to discover under

### S3 bucket resolution

A `Parallel-Block-Initialization` Lambda is automatically inserted before each
parallel block. The bucket it discovers directories in depends on the pipeline
position:

| Scenario | Bucket | Prefix |
|---|---|---|
| `from_step` is set (no `root_prefix`) | Intermediate bucket | `<execution_id>/<from_step>/` |
| `from_step` is set (with `root_prefix`) | Intermediate bucket | `<execution_id>/<from_step>/<root_prefix>/` |
| Previous compute step exists (no `from_step`) | Intermediate bucket | `<execution_id>/<previous_step>/` |
| First step in pipeline (no `from_step`, no previous step) | Source bucket (needs to be defined) | `root_prefix` from execution payload |

When `from_step` is used, the optional `root_prefix` is appended *within* the
from_step's output directory. This allows targeting a specific subdirectory of a
step's output for fan-out. For example, if `prepare_data` writes to both
`validated/` and `rejected/` subdirectories, you can fan out over just the
validated data:

```yaml
steps:
  - name: prepare_data
    type: batch

  - name: process
    type: parallel
    input:
      type: s3
      from_step: prepare_data
      root_prefix: validated
```

This discovers directories under `<exec_id>/prepare_data/validated/`.

The bucket is never user-overridable at execution time — it is always resolved
by OpenTofu based on the pipeline structure. Only `root_prefix` can be
provided in the execution payload, and only when the parallel block is the
first step.

Each iteration receives:

```json
{
  "map_item": "<current array element>",
  "state": { ... entire state at the point the parallel block executes ... }
}
```

| Field      | Source              | Description                                              |
|------------|---------------------|----------------------------------------------------------|
| `map_item` | Current iteration   | The array element for this particular parallel execution |
| `state`    | Parent state        | Full state when the parallel block started               |

### Lambda step (inside parallel block)

| Payload Field              | Source                                                  | Description                                            |
|----------------------------|---------------------------------------------------------|--------------------------------------------------------|
| `SFN_EXECUTION_ID`        | `$$.Execution.Name`                                    | Step Functions execution name                          |
| `MAP_ITEM`                 | `$.map_item`                                           | The current array element for this parallel execution  |
| `STEP_<NAME>`              | `$.state.<step>_result[.Payload]`                      | Each pre-parallel step's result (auto-generated)       |
| `EXECUTION_INPUT`          | `$$.Execution.Input`                             | Full execution input payload                           |

Access in code:
```python
def handler(event, context):
    # Log key presence at INFO; raw values only at DEBUG (may contain caller-supplied secrets/PII)
    for key in (k for k in event.keys() if k.startswith("STEP_")):
        logger.info("Previous step result present", key=key)
        logger.debug("Previous step result value", key=key, value=event[key])
    execution_input = event.get("EXECUTION_INPUT")
    if execution_input:
        logger.info("Execution input received", keys=list(execution_input.keys()))
        logger.debug("Execution input value", execution_input=execution_input)

    event["MAP_ITEM"]                                               # current array element
    event["STEP_SPLITTER"]                                          # pre-parallel lambda result
    event["EXECUTION_INPUT"]                                        # full execution payload

    # Runtime parameters are deploy-time environment variables
    os.environ["CUSTOM_PARAM"]                                      # always the YAML value
```

### Batch step (inside parallel block)

| Env Variable                | Source                                                              | Description                                            |
|-----------------------------|---------------------------------------------------------------------|--------------------------------------------------------|
| `SFN_EXECUTION_ID`         | `$$.Execution.Name`                                                | Step Functions execution name                          |
| `MAP_ITEM`                  | `States.JsonToString($.map_item)`                                  | The current array element (JSON-serialized)            |
| `STEP_<NAME>`               | `States.JsonToString($.state.<step>_result[.Payload])`             | Each pre-parallel step's result (JSON-serialized)      |
| `EXECUTION_INPUT`           | `States.JsonToString($$.Execution.Input)`                    | Full execution input payload (JSON-serialized)         |

Access in code:
```python
import json, os

def main():
    # Log key presence at INFO; raw values only at DEBUG (may contain caller-supplied secrets/PII)
    for key in (k for k in os.environ if k.startswith("STEP_") and k != "STEP_NAME"):
        logger.info("Previous step result present", key=key)
        logger.debug("Previous step result value", key=key, value=os.environ[key])
    execution_input = os.environ.get("EXECUTION_INPUT")
    if execution_input:
        payload = json.loads(execution_input)
        logger.info("Execution input received", keys=list(payload.keys()))
        logger.debug("Execution input value", execution_input=payload)

    json.loads(os.environ["MAP_ITEM"])                                      # array element
    json.loads(os.environ["STEP_SPLITTER"])                                 # pre-parallel step result
    json.loads(os.environ["EXECUTION_INPUT"])                               # full execution payload

    # Runtime parameters are deploy-time environment variables
    os.environ["CUSTOM_PARAM"]                                              # always the YAML value
```

> **Note:** `MAP_ITEM`, `STEP_*`, and `EXECUTION_INPUT` values are JSON-serialized
> strings. Use `json.loads()` to parse them.

---

## Execution input

The full JSON payload used to start the Step Functions execution is passed to
**every step** as `EXECUTION_INPUT`. This means any data you include in the
execution payload is always accessible from any step — no additional
configuration required.

- **Lambda steps** — `event["EXECUTION_INPUT"]` (a Python dict)
- **Batch steps** — `os.environ["EXECUTION_INPUT"]` (a JSON-serialized string, use `json.loads()`)

You can put any keys you want in the execution payload (alongside the required
`inputs` object) and read them from your step code:

```json
{
  "inputs": { "type": "s3", "root_prefix": "upload1/" },
  "SOURCE_PREFIX": "data/2025/batch-42/",
  "NOTIFY_ON_COMPLETION": true,
  "CLIENT_ID": "customer-xyz"
}
```

```python
import json, os

# Batch step
exec_input = json.loads(os.environ.get("EXECUTION_INPUT", "{}"))
source_prefix = exec_input.get("SOURCE_PREFIX", "")
client_id = exec_input.get("CLIENT_ID", "")

# Lambda step
def handler(event, context):
    exec_input = event.get("EXECUTION_INPUT", {})
    source_prefix = exec_input.get("SOURCE_PREFIX", "")
    client_id = exec_input.get("CLIENT_ID", "")
```

This is useful for passing runtime context (batch identifiers, feature flags,
caller metadata, etc.) without needing to redeploy infrastructure.

---

## Runtime parameters

Any step (batch or lambda) can define `runtime_parameters` in the pipeline YAML:

```yaml
- name: my-step
  type: batch
  runtime_parameters:
    CUSTOM_PARAM: "default_value"
```

Runtime parameters are **deploy-time environment variables**. The key becomes the
environment variable name and the value becomes its static default, set on the
Lambda function or Batch job definition at deploy time. Values must be non-empty
strings.

- **Batch steps** — each key-value pair is added to the container's `environment`
  in the job definition.
- **Lambda steps** — each key-value pair is added to the Lambda function's
  environment variables.

### Overriding runtime parameters via EXECUTION_INPUT

Since `EXECUTION_INPUT` is always available, you can use it to override
deploy-time defaults on a per-execution basis. This is optional — it's just a
pattern your code can implement if needed:

```python
import json, os

# Batch step
exec_input = json.loads(os.environ.get("EXECUTION_INPUT", "{}"))
custom_param = exec_input.get("CUSTOM_PARAM", os.environ.get("CUSTOM_PARAM", ""))

# Lambda step
def handler(event, context):
    exec_input = event.get("EXECUTION_INPUT", {})
    custom_param = exec_input.get("CUSTOM_PARAM", os.environ.get("CUSTOM_PARAM", ""))
```

This gives you a two-layer system:
1. **Deploy-time default** — from `runtime_parameters` in the YAML (`os.environ`)
2. **Execution-time override** — from the Step Functions payload (`EXECUTION_INPUT`)

The code decides which to use. The convention is: if the key exists in
`EXECUTION_INPUT`, use it; otherwise fall back to `os.environ`.

### Example

Given this pipeline definition:

```yaml
steps:
  - name: ingest
    type: batch
    runtime_parameters:
      SOURCE_PREFIX: "data/default/"
      SOURCE_SYSTEM: "sensor-array-north"
```

At deploy time, the Batch job definition gets these environment variables:

| Env Variable | Value |
|---|---|
| `SOURCE_PREFIX` | `data/default/` |
| `SOURCE_SYSTEM` | `sensor-array-north` |

When you start an execution with:

```json
{
  "inputs": { "type": "s3", "root_prefix": "upload1/" },
  "SOURCE_PREFIX": "data/2025/batch-42/"
}
```

The batch container sees:

| Source | Variable | Value |
|---|---|---|
| `os.environ` (deploy-time) | `SOURCE_PREFIX` | `data/default/` |
| `os.environ` (deploy-time) | `SOURCE_SYSTEM` | `sensor-array-north` |
| `EXECUTION_INPUT` (runtime) | full payload | `{"inputs": {...}, "SOURCE_PREFIX": "data/2025/batch-42/"}` |

Code that follows the override pattern:
```python
exec_input = json.loads(os.environ.get("EXECUTION_INPUT", "{}"))
source_prefix = exec_input.get("SOURCE_PREFIX", os.environ.get("SOURCE_PREFIX", ""))
# → "data/2025/batch-42/" (execution input wins)

source_system = exec_input.get("SOURCE_SYSTEM", os.environ.get("SOURCE_SYSTEM", ""))
# → "sensor-array-north" (falls back to deploy-time default)
```

---

## ResultSelector (what gets stored vs. what's in execution history)

Each step uses `ResultSelector` to trim the raw output before storing it in the
state machine data:

### Lambda steps

Raw output from Step Functions Lambda integration:
```json
{
  "ExecutedVersion": "$LATEST",
  "Payload": { "status": "success", "items": [...] },
  "SdkHttpMetadata": { ... },
  "SdkResponseMetadata": { ... },
  "StatusCode": 200
}
```

After `ResultSelector`, stored at `$.<step_name>_result`:
```json
{
  "Payload": { "status": "success", "items": [...] }
}
```

### Batch steps

Raw output from Step Functions Batch integration:
```json
{
  "JobName": "...", "JobId": "...", "JobArn": "...",
  "Status": "SUCCEEDED",
  "Container": { "ExitCode": 0, "LogStreamName": "...", ... },
  "Attempts": [...],
  ...
}
```

After `ResultSelector`, stored at `$.<step_name>_result`:
```json
{
  "status": "SUCCEEDED",
  "job_id": "32a2eae3-...",
  "exit_code": 0
}
```

The full raw output is always available in the Step Functions execution history
(via the console or `GetExecutionHistory` API) for debugging and auditing.

---

## Example: full pipeline with parallel block

```yaml
steps:
  - name: pre_processing
    type: lambda
    # Receives: SFN_EXECUTION_ID, EXECUTION_INPUT
    # No STEP_* vars (first step)

  - name: process
    type: parallel
    input:
      type: custom
      from_step: pre_processing
      field: items
    parallel_steps:
      - name: process_one
        type: lambda
        # Receives:
        #   MAP_ITEM                    = current array element
        #   STEP_PRE_PROCESSING         = pre_processing Lambda return value (auto)
        #   EXECUTION_INPUT             = full execution payload

  - name: aggregate
    type: batch
    # Receives:
    #   STEP_PRE_PROCESSING         = pre_processing Lambda return value (auto)
    #   STEP_PROCESS                = {"status": "COMPLETED"} (auto, parallel block)
    #   EXECUTION_INPUT             = full execution payload (JSON-serialized)
```

The full execution flow:

```
pre_processing  →  Parallel-Block-Initialization (auto)  →  process (parallel)  →  aggregate  →  Completion
```
