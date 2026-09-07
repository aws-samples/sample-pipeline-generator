# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: MIT-0

"""Batch step (inside parallel): Transform a single chunk of data.

Runs inside the parallel Map block. Each invocation receives one chunk
via the MAP_ITEM environment variable containing the chunk object from
split-workload.

Environment variables (set by pipeline):
    STEP_NAME, INTERMEDIATE_BUCKET, SOURCE_BUCKET, SSM_PARAMS_PREFIX,
    SECRETS_PREFIX, SFN_EXECUTION_ID, MAP_ITEM, STATE, TRANSFORM_CONFIG
"""

import json
import os

import boto3
from aws_lambda_powertools import Logger

logger = Logger(service="complex-example-transform-chunk")
PIPELINE_NAME = os.environ.get("PIPELINE_NAME", "unknown")
STEP_NAME = os.environ.get("STEP_NAME", "unknown")
SFN_EXECUTION_ID = os.environ["SFN_EXECUTION_ID"]

logger.append_keys(step_name=STEP_NAME)
logger.append_keys(run_id=SFN_EXECUTION_ID)
logger.append_keys(pipeline_name=PIPELINE_NAME)


def main():
    # Log only presence and size of STEP_* payloads at INFO; gate raw values
    # behind DEBUG so this copy-template step does not spill upstream,
    # potentially caller-supplied, data into CloudWatch Logs when copied into
    # production. See the pipeline README security note.
    for key, value in os.environ.items():
        if key.startswith("STEP_") and key != "STEP_NAME":
            logger.info(
                "Previous step result present", key=key, size=len(value)
            )
            logger.debug("Previous step result value", key=key, value=value)

    # Do NOT log the raw execution input at INFO — it is caller-supplied and
    # may contain sensitive data. Log key names / size only; raw at DEBUG.
    execution_input_raw = os.environ.get("EXECUTION_INPUT")
    if execution_input_raw:
        execution_input = json.loads(execution_input_raw)
        logger.info(
            "Execution input received",
            keys=list(execution_input.keys())
            if isinstance(execution_input, dict)
            else None,
            size_bytes=len(execution_input_raw),
        )
        logger.debug("Execution input value", execution_input=execution_input)

    step_name = os.environ["STEP_NAME"]
    intermediate_bucket = os.environ["INTERMEDIATE_BUCKET"]
    source_bucket = os.environ.get("SOURCE_BUCKET", "")
    sfn_execution_id = os.environ["SFN_EXECUTION_ID"]
    transform_config = os.environ.get("TRANSFORM_CONFIG", "default")

    # Parse the chunk assigned to this iteration
    map_item_raw = os.environ.get("MAP_ITEM", "{}")
    map_item = (
        json.loads(map_item_raw)
        if isinstance(map_item_raw, str)
        else map_item_raw
    )

    chunk_id = map_item.get("chunk_id", 0)
    object_keys = map_item.get("object_keys", [])

    # Verify previous step outputs passed into the parallel block
    # Inside Map, pre-parallel steps are passed via STEP_ env vars
    expected_prev_steps = [
        "STEP_INGEST_RAW_DATA",
        "STEP_VALIDATE_INGESTION",
        "STEP_SPLIT_WORKLOAD",
    ]
    for key in expected_prev_steps:
        prev_data = os.environ.get(key)
        if prev_data is not None:
            logger.info(
                "Received previous step output",
                key=key,
                data_length=len(prev_data),
            )
        else:
            logger.warning("Missing expected previous step output", key=key)

    logger.info(
        "Starting chunk transform",
        chunk_id=chunk_id,
        object_count=len(object_keys),
        transform_config=transform_config,
    )

    s3 = boto3.client("s3")
    transformed_records = []

    for key in object_keys:
        try:
            obj = s3.get_object(Bucket=source_bucket, Key=key)
            raw_data = obj["Body"].read().decode()

            # Apply transformation (placeholder — real logic depends on use case)
            transformed = _transform_record(raw_data, transform_config)
            transformed_records.append(
                {
                    "source_key": key,
                    "record_count": len(transformed),
                    "status": "transformed",
                }
            )

            # Write transformed data to intermediate bucket
            output_key = f"{sfn_execution_id}/{step_name}/chunk-{chunk_id}/{os.path.basename(key)}"
            s3.put_object(
                Bucket=intermediate_bucket,
                Key=output_key,
                Body=json.dumps(transformed),
                ContentType="application/json",
            )

        except Exception as e:
            logger.error("Failed to transform object", key=key, error=str(e))
            transformed_records.append(
                {
                    "source_key": key,
                    "record_count": 0,
                    "status": "error",
                    "error": str(e),
                }
            )

    # Write chunk summary
    summary = {
        "chunk_id": chunk_id,
        "transform_config": transform_config,
        "total_objects": len(object_keys),
        "transformed": sum(
            1 for r in transformed_records if r["status"] == "transformed"
        ),
        "errors": sum(
            1 for r in transformed_records if r["status"] == "error"
        ),
        "records": transformed_records,
    }

    summary_key = (
        f"{sfn_execution_id}/{step_name}/chunk-{chunk_id}/summary.json"
    )
    s3.put_object(
        Bucket=intermediate_bucket,
        Key=summary_key,
        Body=json.dumps(summary),
        ContentType="application/json",
    )

    logger.info(
        "Chunk transform complete",
        chunk_id=chunk_id,
        transformed=summary["transformed"],
        errors=summary["errors"],
    )


def _transform_record(raw_data, config):
    """Apply transformation to raw data. Placeholder implementation."""
    try:
        records = [
            json.loads(line)
            for line in raw_data.strip().split("\n")
            if line.strip()
        ]
    except json.JSONDecodeError:
        records = [{"raw": raw_data}]

    # Placeholder: add metadata to each record
    for record in records:
        record["_transform_config"] = config
        record["_transformed"] = True

    return records


if __name__ == "__main__":
    main()
