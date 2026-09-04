# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: MIT-0

"""Lambda step (inside parallel): Score a transformed chunk.

Runs inside the parallel Map block after transform-chunk. Reads the
transformed data and applies a scoring model, writing scored results
to the intermediate bucket.

Environment variables (set by pipeline):
    STEP_NAME, INTERMEDIATE_BUCKET, SSM_PARAMS_PREFIX, SECRETS_PREFIX

Payload fields (from Step Functions):
    SFN_EXECUTION_ID, MAP_ITEM, STATE
"""

import json
import os

import boto3
from aws_lambda_powertools import Logger

logger = Logger(service="end-to-end-score-chunk")
PIPELINE_NAME = os.environ.get("PIPELINE_NAME", "unknown")
STEP_NAME = os.environ.get("STEP_NAME", "unknown")

logger.append_keys(step_name=STEP_NAME)
logger.append_keys(pipeline_name=PIPELINE_NAME)


s3 = boto3.client("s3")


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
    map_item = event.get("MAP_ITEM", {})
    if isinstance(map_item, str):
        map_item = json.loads(map_item)

    chunk_id = map_item.get("chunk_id", 0)

    # Verify previous step outputs passed into the parallel block
    # Inside Map, pre-parallel steps come via payload; transform_chunk is the prior parallel step
    expected_prev_steps = [
        "STEP_INGEST_RAW_DATA",
        "STEP_VALIDATE_INGESTION",
        "STEP_SPLIT_WORKLOAD",
    ]
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

    logger.info("Starting chunk scoring", chunk_id=chunk_id)

    # Read the transform summary for this chunk
    summary_key = (
        f"{sfn_execution_id}/transform_chunk/chunk-{chunk_id}/summary.json"
    )
    try:
        summary_obj = s3.get_object(
            Bucket=intermediate_bucket, Key=summary_key
        )
        summary = json.loads(summary_obj["Body"].read().decode())
    except Exception:
        logger.warning("Could not read transform summary", key=summary_key)
        summary = {"records": []}

    # Score each transformed record
    scored_records = []
    for record in summary.get("records", []):
        if record.get("status") != "transformed":
            continue

        score = _compute_score(record)
        scored_records.append(
            {
                "source_key": record["source_key"],
                "record_count": record["record_count"],
                "score": score,
                "label": "high" if score >= 0.7 else "low",
            }
        )

    # Write scored results
    result = {
        "chunk_id": chunk_id,
        "total_scored": len(scored_records),
        "avg_score": (
            sum(r["score"] for r in scored_records) / len(scored_records)
            if scored_records
            else 0.0
        ),
        "high_count": sum(1 for r in scored_records if r["label"] == "high"),
        "low_count": sum(1 for r in scored_records if r["label"] == "low"),
        "records": scored_records,
    }

    result_key = f"{sfn_execution_id}/{step_name}/chunk-{chunk_id}/scores.json"
    s3.put_object(
        Bucket=intermediate_bucket,
        Key=result_key,
        Body=json.dumps(result),
        ContentType="application/json",
    )

    logger.info(
        "Chunk scoring complete",
        chunk_id=chunk_id,
        total_scored=result["total_scored"],
        avg_score=round(result["avg_score"], 3),
    )

    return {
        "status": "success",
        "chunk_id": chunk_id,
        "total_scored": result["total_scored"],
        "avg_score": result["avg_score"],
    }


def _compute_score(record):
    """Compute a quality score for a record. Placeholder implementation."""
    record_count = record.get("record_count", 0)
    if record_count == 0:
        return 0.0
    # Simple heuristic: more records = higher score, capped at 1.0
    return min(record_count / 100.0, 1.0)
