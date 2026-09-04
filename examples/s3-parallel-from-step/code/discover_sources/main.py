# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: MIT-0

"""Lambda step: discover and validate sources written by prepare_data.

This step runs between prepare_data and the parallel block. It verifies
that the expected subdirectories exist and returns metadata about them.
The parallel block uses `from_step: prepare_data` (not this step) for
S3 discovery, so this step serves as an intermediate validation/enrichment
step that demonstrates from_step targeting a non-adjacent step.

Environment variables (set by pipeline):
    STEP_NAME, INTERMEDIATE_BUCKET

Payload fields (from Step Functions):
    SFN_EXECUTION_ID, STEP_PREPARE_DATA (previous step result)
"""

import os

import boto3
from aws_lambda_powertools import Logger

logger = Logger(service="s3-parallel-from-step-discover-sources")

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
        logger.info("Execution input received")
        logger.debug("Execution input value", execution_input=execution_input)

    step_name = os.environ["STEP_NAME"]
    intermediate_bucket = os.environ["INTERMEDIATE_BUCKET"]
    sfn_execution_id = event["SFN_EXECUTION_ID"]

    # Get the output from prepare_data
    prepare_data_result = event.get("STEP_PREPARE_DATA", {})

    logger.info(
        "Discovering sources",
        step_name=step_name,
        execution_id=sfn_execution_id,
        prepare_data_keys=list(prepare_data_result.keys())
        if isinstance(prepare_data_result, dict)
        else None,
    )
    logger.debug(
        "prepare_data raw result",
        prepare_data_result=prepare_data_result,
    )

    # List objects under the prepare_data output prefix to validate
    prefix = f"{sfn_execution_id}/prepare_data/"
    response = s3.list_objects_v2(
        Bucket=intermediate_bucket,
        Prefix=prefix,
        Delimiter="/",
    )

    discovered_prefixes = [
        p["Prefix"] for p in response.get("CommonPrefixes", [])
    ]

    logger.info(
        "Discovery complete",
        discovered_count=len(discovered_prefixes),
        prefixes=discovered_prefixes,
    )

    return {
        "status": "success",
        "source_step": "prepare_data",
        "discovered_count": len(discovered_prefixes),
        "prefixes": discovered_prefixes,
    }
