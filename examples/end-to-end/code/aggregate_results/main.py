# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: MIT-0

"""Batch step: Aggregate results from all parallel chunks.

Reads scored results from all chunks produced by the parallel Map block,
computes aggregate statistics, and writes a final consolidated report.

This step has copy_to_target=true, so its output in the intermediate
bucket will be copied to the output bucket by the pipeline's
Copy-To-Output step.

Environment variables (set by pipeline):
    STEP_NAME, INTERMEDIATE_BUCKET, OUTPUT_BUCKET, SOURCE_BUCKET,
    SSM_PARAMS_PREFIX, SECRETS_PREFIX, SFN_EXECUTION_ID, STATE
"""

import json
import os

import boto3
from aws_lambda_powertools import Logger

logger = Logger(service="end-to-end-aggregate-results")
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

    step_name = STEP_NAME
    intermediate_bucket = os.environ["INTERMEDIATE_BUCKET"]
    sfn_execution_id = SFN_EXECUTION_ID

    # Verify previous step outputs: all pre-parallel steps + parallel block result
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

    logger.info("Starting aggregation", execution_id=sfn_execution_id)

    s3 = boto3.client("s3")

    # Discover all score files from the parallel step
    score_prefix = f"{sfn_execution_id}/score_chunk/"
    paginator = s3.get_paginator("list_objects_v2")

    all_chunk_results = []
    for page in paginator.paginate(
        Bucket=intermediate_bucket, Prefix=score_prefix
    ):
        for obj in page.get("Contents", []):
            if obj["Key"].endswith("/scores.json"):
                score_obj = s3.get_object(
                    Bucket=intermediate_bucket, Key=obj["Key"]
                )
                chunk_result = json.loads(score_obj["Body"].read().decode())
                all_chunk_results.append(chunk_result)

    logger.info("Loaded chunk results", total_chunks=len(all_chunk_results))

    # Compute aggregate statistics
    total_scored = sum(c.get("total_scored", 0) for c in all_chunk_results)
    total_high = sum(c.get("high_count", 0) for c in all_chunk_results)
    total_low = sum(c.get("low_count", 0) for c in all_chunk_results)

    all_scores = [
        r["score"] for c in all_chunk_results for r in c.get("records", [])
    ]
    avg_score = sum(all_scores) / len(all_scores) if all_scores else 0.0

    # Build final report
    report = {
        "execution_id": sfn_execution_id,
        "total_chunks_processed": len(all_chunk_results),
        "total_records_scored": total_scored,
        "high_quality_records": total_high,
        "low_quality_records": total_low,
        "overall_avg_score": round(avg_score, 4),
        "chunk_summaries": [
            {
                "chunk_id": c["chunk_id"],
                "scored": c["total_scored"],
                "avg_score": round(c.get("avg_score", 0), 4),
            }
            for c in all_chunk_results
        ],
    }

    # Write to intermediate bucket (will be copied to output by Copy-To-Output)
    report_key = f"{sfn_execution_id}/{step_name}/aggregated_report.json"
    s3.put_object(
        Bucket=intermediate_bucket,
        Key=report_key,
        Body=json.dumps(report, indent=2),
        ContentType="application/json",
    )

    logger.info(
        "Aggregation complete",
        total_scored=total_scored,
        avg_score=round(avg_score, 4),
        high=total_high,
        low=total_low,
    )


if __name__ == "__main__":
    main()
