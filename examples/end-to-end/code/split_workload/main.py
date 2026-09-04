# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: MIT-0

"""Lambda step: Split workload into chunks for parallel processing.

Reads the validation report from validate-ingestion, groups valid objects
into chunks, and returns the chunk list for the parallel Map block.

The returned 'chunks' field is referenced by the parallel step via:
    input:
      type: custom
      from_step: split-workload
      field: chunks

Environment variables (set by pipeline):
    STEP_NAME, INTERMEDIATE_BUCKET, SSM_PARAMS_PREFIX, SECRETS_PREFIX

Payload fields (from Step Functions):
    SFN_EXECUTION_ID, STATE
"""

import json
import math
import os

import boto3
from aws_lambda_powertools import Logger

logger = Logger(service="end-to-end-split-workload")
PIPELINE_NAME = os.environ.get("PIPELINE_NAME", "unknown")
STEP_NAME = os.environ.get("STEP_NAME", "unknown")

logger.append_keys(step_name=STEP_NAME)
logger.append_keys(pipeline_name=PIPELINE_NAME)
s3 = boto3.client("s3")

DEFAULT_CHUNK_SIZE = 2


@logger.inject_lambda_context
def handler(event, context):
    run_id = event.get("SFN_EXECUTION_ID")
    if run_id:
        logger.append_keys(run_id=run_id)
    # Log only key presence at INFO; gate raw values behind DEBUG so this
    # copy-template step does not spill caller-supplied data into CloudWatch
    # Logs by default. See the pipeline README security note.
    for key in (k for k in event.keys() if k.startswith("STEP_")):
        logger.info("Previous step result present", key=key)
        logger.debug("Previous step result value", key=key, value=event[key])
    execution_input = event.get("EXECUTION_INPUT")
    if execution_input:
        logger.info(
            "Execution input received",
            keys=list(execution_input.keys())
            if isinstance(execution_input, dict)
            else None,
        )
        logger.debug("Execution input value", execution_input=execution_input)

    step_name = os.environ["STEP_NAME"]
    intermediate_bucket = os.environ["INTERMEDIATE_BUCKET"]

    sfn_execution_id = event.get("SFN_EXECUTION_ID", "unknown")

    # Verify previous step outputs: should have STEP_INGEST_RAW_DATA and STEP_VALIDATE_INGESTION
    expected_prev_steps = ["STEP_INGEST_RAW_DATA", "STEP_VALIDATE_INGESTION"]
    for key in expected_prev_steps:
        prev_data = event.get(key)
        if prev_data is not None:
            logger.info("Received previous step output", key=key)
            logger.debug(
                "Received previous step output value", key=key, data=prev_data
            )
        else:
            logger.warning(
                "Missing expected previous step output",
                key=key,
                available_keys=list(event.keys()),
            )

    logger.info("Starting workload split", execution_id=sfn_execution_id)

    # Read validation report from previous step
    report_key = (
        f"{sfn_execution_id}/validate_ingestion/validation_report.json"
    )
    try:
        report_obj = s3.get_object(Bucket=intermediate_bucket, Key=report_key)
        report = json.loads(report_obj["Body"].read().decode())
    except Exception:
        logger.warning("Could not read validation report, using state data")
        report = {"objects": []}

    # Filter to valid objects only
    valid_objects = [
        o for o in report.get("objects", []) if o.get("valid", True)
    ]

    if not valid_objects:
        logger.warning("No valid objects to process")
        return {"status": "success", "chunks": [], "total_chunks": 0}

    # Split into chunks
    chunk_size = DEFAULT_CHUNK_SIZE
    total_chunks = math.ceil(len(valid_objects) / chunk_size)

    chunks = []
    for i in range(total_chunks):
        start = i * chunk_size
        end = min(start + chunk_size, len(valid_objects))
        chunk_objects = valid_objects[start:end]

        chunks.append(
            {
                "chunk_id": i,
                "object_keys": [o["key"] for o in chunk_objects],
                "object_count": len(chunk_objects),
            }
        )

    # Write split plan to intermediate bucket
    plan = {
        "total_valid_objects": len(valid_objects),
        "chunk_size": chunk_size,
        "total_chunks": total_chunks,
        "chunks": chunks,
    }

    plan_key = f"{sfn_execution_id}/{step_name}/split_plan.json"
    s3.put_object(
        Bucket=intermediate_bucket,
        Key=plan_key,
        Body=json.dumps(plan),
        ContentType="application/json",
    )

    logger.info(
        "Workload split complete",
        total_objects=len(valid_objects),
        total_chunks=total_chunks,
        chunk_size=chunk_size,
    )

    # Return chunks — this is what the parallel Map block iterates over
    return {
        "status": "success",
        "chunks": chunks,
        "total_chunks": total_chunks,
    }
