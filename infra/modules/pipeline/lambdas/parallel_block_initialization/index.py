# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: MIT-0

import boto3
from aws_lambda_powertools import Logger
import os

logger = Logger(service="parallel_block_initialization")


def _discover_s3(bucket: str, root_prefix: str) -> list[str]:
    """List immediate child prefixes under a root prefix in an S3 bucket.

    When root_prefix is empty, discovers top-level directories in the bucket.
    """
    stripped = root_prefix.strip("/")
    prefix = f"{stripped}/" if stripped else ""

    logger.info(f"Discovering directories in s3://{bucket}/{prefix}")

    s3 = boto3.client("s3")
    paginator = s3.get_paginator("list_objects_v2")
    pages = paginator.paginate(Bucket=bucket, Prefix=prefix, Delimiter="/")

    directories = []
    for page in pages:
        for prefix_info in page.get("CommonPrefixes", []):
            directories.append(prefix_info["Prefix"])

    logger.info(f"Found {len(directories)} directories: {directories}")
    return directories


@logger.inject_lambda_context
def handler(event, context):
    """
    Resolve inputs for a parallel block based on input type:
      - s3: list nested directories under an S3 prefix
      - custom: pass through a user-provided list of values

    Bucket resolution for S3 discovery (in priority order):
      1. from_step is set       → INTERMEDIATE_BUCKET env var at <exec_id>/<from_step>/
      2. previous_step is set   → INTERMEDIATE_BUCKET env var at <exec_id>/<previous_step>/
      3. First step (neither)   → SOURCE_BUCKET env var (falls back to
         INTERMEDIATE_BUCKET if not set) with root_prefix from inputs
    """
    try:
        inputs = event["inputs"]
        input_type = inputs["type"]

        # Environment variables
        intermediate_bucket = os.environ["INTERMEDIATE_BUCKET"]

        # Event variables
        execution_id = event["SFN_EXECUTION_ID"]
        step_name = event["STEP_NAME"]

        logger.append_keys(step_name=step_name)
        logger.append_keys(run_id=execution_id)

        discovery_bucket = intermediate_bucket

        if input_type == "s3":
            from_step = inputs.get("from_step")

            if from_step:
                # Explicit from_step: read from intermediate bucket using
                # that step's output prefix: <execution_id>/<step_name>/
                root_prefix = inputs.get("root_prefix", "")
                if root_prefix is None:
                    root_prefix = ""
                else:
                    root_prefix = root_prefix.strip("/")
                root_prefix = (
                    f"{execution_id}/{from_step}/{root_prefix}"
                    if root_prefix
                    else f"{execution_id}/{from_step}"
                )
            else:
                previous_step = event.get("previous_step")

                if previous_step:
                    # There is a preceding compute step — always use the
                    # intermediate bucket at <execution_id>/<previous_step>/
                    root_prefix = f"{execution_id}/{previous_step}"
                else:
                    # First step in the pipeline — use the source bucket
                    # (injected by OpenTofu) with root_prefix from the
                    # execution payload
                    source_bucket = os.environ.get("SOURCE_BUCKET")
                    if source_bucket:
                        discovery_bucket = source_bucket
                        logger.info("Using source bucket for discovery")
                    else:
                        logger.warning(
                            "No source bucket defined, falling back to intermediate bucket for discovery."
                        )

                    root_prefix = inputs.get("root_prefix")
                    if root_prefix is None:
                        raise ValueError(
                            "root_prefix is required when the parallel "
                            "block is the first step"
                        )

            directories = _discover_s3(discovery_bucket, root_prefix)
            logger.info(f"S3 discovery found {len(directories)} directories")

            if not directories:
                raise Exception("No directories found in S3 discovery")

            return {
                "statusCode": 200,
                "source_paths": directories,
                "resolved_bucket": discovery_bucket,
            }

        if input_type == "custom":
            from_step = inputs.get("from_step")

            if from_step:
                # Read from the previous step's output field
                field = inputs.get("field")
                if not field:
                    raise ValueError(
                        "field must be provided when using custom type with from_step"
                    )
                # The step result is passed in the event under the step's
                # result key
                step_result = event.get("from_step_result")
                if step_result is None:
                    raise ValueError(
                        f"from_step_result not found in event for step '{from_step}'"
                    )
                # Navigate the field path (supports dot notation)
                values = step_result
                for part in field.split("."):
                    if isinstance(values, dict):
                        values = values[part]
                    else:
                        raise ValueError(
                            f"Cannot navigate field path '{field}' — "
                            f"'{part}' is not a dict key"
                        )
                if not isinstance(values, list):
                    values = [values]
                logger.info(
                    f"Custom input from step '{from_step}' with "
                    f"{len(values)} values"
                )
                logger.debug(f"Custom input values: {values}")
                return {
                    "statusCode": 200,
                    "source_paths": values,
                    "resolved_bucket": None,
                }

            # No from_step: passthrough from execution payload
            values = inputs["value"]
            if not isinstance(
                values, list
            ):  # if the user only sends one value in payload
                values = [values]
            logger.info(f"Custom input with {len(values)} values")
            logger.debug(f"Custom input values: {values}")
            return {
                "statusCode": 200,
                "source_paths": values,
                "resolved_bucket": None,
            }

        raise ValueError(f"Unsupported input type: {input_type}")

    except Exception as e:
        logger.error(f"Error in parallel block initialization: {str(e)}")
        raise e
