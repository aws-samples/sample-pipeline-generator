# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: MIT-0

"""Lambda step: prepare data by writing subdirectories to the intermediate bucket.

Creates a few subdirectories under <execution_id>/<step_name>/ so the
subsequent parallel block can discover them via S3 discovery using from_step.

Environment variables (set by pipeline):
    STEP_NAME, INTERMEDIATE_BUCKET

Payload fields (from Step Functions):
    SFN_EXECUTION_ID
"""

import json
import os

import boto3
from aws_lambda_powertools import Logger

logger = Logger(service="s3-parallel-from-step-prepare-data")

s3 = boto3.client("s3")


def handler(event, context):
    # Log only key presence at INFO; gate raw values behind DEBUG. prepare_data
    # is the entry step and its execution input is directly caller-supplied, so
    # logging raw values at INFO would spill customer data into CloudWatch Logs.
    for key in (k for k in event.keys() if k.startswith("STEP_")):
        logger.info("Previous step result present", key=key)
        logger.debug("Previous step result value", key=key, value=event[key])
    execution_input = event.get("EXECUTION_INPUT")
    if execution_input:
        logger.info("Execution input received")
        logger.debug("Execution input value", execution_input=execution_input)

    step_name = os.environ["STEP_NAME"]
    intermediate_bucket = os.environ["INTERMEDIATE_BUCKET"]
    sfn_execution_id = event["SFN_EXECUTION_ID"]

    logger.info(
        "Preparing data",
        step_name=step_name,
        execution_id=sfn_execution_id,
    )

    # Write files into subdirectories so the parallel block can discover them
    subdirs = ["batch-a", "batch-b", "batch-c"]
    for subdir in subdirs:
        key = f"{sfn_execution_id}/{step_name}/{subdir}/data.json"
        s3.put_object(
            Bucket=intermediate_bucket,
            Key=key,
            Body=json.dumps({"batch": subdir, "status": "ready"}),
            ContentType="application/json",
        )
        logger.info("Created subdirectory", key=key)

    logger.info(
        "Data preparation complete",
        subdirectories=len(subdirs),
    )

    return {"status": "success", "subdirectories": subdirs}
