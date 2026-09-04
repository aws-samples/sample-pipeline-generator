# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: MIT-0

"""Lambda step: Publish the final report.

Reads the aggregated report from aggregate-results, formats it for
distribution, and writes the final output. This is the last compute
step before the pipeline completion notification.

Environment variables (set by pipeline):
    STEP_NAME, INTERMEDIATE_BUCKET, OUTPUT_BUCKET, SSM_PARAMS_PREFIX,
    SECRETS_PREFIX, REPORT_FORMAT, DISTRIBUTION_LIST

Payload fields (from Step Functions):
    SFN_EXECUTION_ID, STATE
"""

import json
import os
from datetime import datetime, timezone

import boto3
from aws_lambda_powertools import Logger

logger = Logger(service="end-to-end-publish-report")
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
    report_format = os.environ.get("REPORT_FORMAT", "json")
    distribution_list = os.environ.get("DISTRIBUTION_LIST", "")

    sfn_execution_id = event.get("SFN_EXECUTION_ID", "unknown")

    # Verify previous step outputs: all preceding steps should be available
    expected_prev_steps = [
        "STEP_INGEST_RAW_DATA",
        "STEP_VALIDATE_INGESTION",
        "STEP_SPLIT_WORKLOAD",
        "STEP_AGGREGATE_RESULTS",
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

    logger.info(
        "Starting report publication",
        execution_id=sfn_execution_id,
        format=report_format,
    )

    # Read the aggregated report
    report_key = f"{sfn_execution_id}/aggregate_results/aggregated_report.json"
    try:
        report_obj = s3.get_object(Bucket=intermediate_bucket, Key=report_key)
        report = json.loads(report_obj["Body"].read().decode())
    except Exception:
        logger.warning(
            "Could not read aggregated report, building minimal report"
        )
        report = {"execution_id": sfn_execution_id, "status": "partial"}

    # Format the report
    published_report = {
        "title": f"Pipeline Report — {sfn_execution_id}",
        "generated_at": datetime.now(timezone.utc).isoformat(),
        "format": report_format,
        "distribution": distribution_list.split(",")
        if distribution_list
        else [],
        "summary": {
            "total_records": report.get("total_records_scored", 0),
            "avg_score": report.get("overall_avg_score", 0),
            "high_quality": report.get("high_quality_records", 0),
            "low_quality": report.get("low_quality_records", 0),
            "chunks_processed": report.get("total_chunks_processed", 0),
        },
        "details": report.get("chunk_summaries", []),
    }

    # Write to intermediate bucket
    output_key = f"{sfn_execution_id}/{step_name}/published_report.json"
    s3.put_object(
        Bucket=intermediate_bucket,
        Key=output_key,
        Body=json.dumps(published_report, indent=2),
        ContentType="application/json",
    )

    logger.info(
        "Report published",
        output=f"s3://{intermediate_bucket}/{output_key}",
        total_records=published_report["summary"]["total_records"],
    )

    return {
        "status": "success",
        "report_path": f"s3://{intermediate_bucket}/{output_key}",
        "total_records": published_report["summary"]["total_records"],
        "avg_score": published_report["summary"]["avg_score"],
    }
