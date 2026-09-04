# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: MIT-0

"""Lambda step: process a single item from the S3 discovery fan-out.

Receives MAP_ITEM (the discovered S3 prefix) and writes a marker file
to the intermediate bucket to confirm processing.

Environment variables (set by pipeline):
    STEP_NAME, INTERMEDIATE_BUCKET, SOURCE_BUCKET

Payload fields (from Step Functions):
    SFN_EXECUTION_ID, MAP_ITEM
"""

import json
import os

import boto3
from aws_lambda_powertools import Logger

logger = Logger(service="s3-parallel-first-process-item")

s3 = boto3.client("s3")


def handler(event, context):
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
    sfn_execution_id = event["SFN_EXECUTION_ID"]
    map_item = event["MAP_ITEM"]

    logger.info(
        "Processing item",
        step_name=step_name,
        execution_id=sfn_execution_id,
        map_item=map_item,
    )

    # Write a marker to intermediate bucket.
    # map_item already includes the execution_id and source step prefix
    # (e.g. "<exec_id>/<source_step>/batch-a/"), so we only prepend step_name
    # relative to the execution to avoid path duplication.
    output_key = f"{sfn_execution_id}/{step_name}/{map_item.split('/', 2)[-1]}processed.json"
    s3.put_object(
        Bucket=intermediate_bucket,
        Key=output_key,
        Body=json.dumps({"source": map_item, "status": "processed"}),
        ContentType="application/json",
    )

    logger.info("Item processed", output_key=output_key)

    return {"status": "success", "source": map_item}
