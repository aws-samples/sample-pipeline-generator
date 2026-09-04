#!/usr/bin/env python3

# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: MIT-0


import os
import sys
import boto3
from aws_lambda_powertools import Logger

logger = Logger()
s3 = boto3.client("s3")


def copy_objects(source_bucket: str, dest_bucket: str, prefix: str) -> int:
    """Copy all objects under a prefix from source to destination bucket.

    Args:
        source_bucket: Name of the source S3 bucket.
        dest_bucket: Name of the destination S3 bucket.
        prefix: S3 key prefix to copy.

    Returns:
        Number of objects copied.
    """
    paginator = s3.get_paginator("list_objects_v2")
    pages = paginator.paginate(Bucket=source_bucket, Prefix=prefix)

    copied = 0
    for page in pages:
        for obj in page.get("Contents", []):
            key = obj["Key"]
            copy_source = {"Bucket": source_bucket, "Key": key}
            s3.copy_object(
                CopySource=copy_source,
                Bucket=dest_bucket,
                Key=key,
            )
            copied += 1

    return copied


def main():
    """Copy data from intermediate bucket to output bucket for specified steps."""
    # Get required environment variables
    intermediate_bucket = os.environ["INTERMEDIATE_BUCKET"]
    output_bucket = os.environ["OUTPUT_BUCKET"]
    execution_id = os.environ["SFN_EXECUTION_ID"]
    step_names = os.environ["SOURCE_STEP_NAMES"].split(",")

    logger.info(
        "Starting data copy",
        extra={
            "execution_id": execution_id,
            "intermediate_bucket": intermediate_bucket,
            "output_bucket": output_bucket,
            "step_names": step_names,
        },
    )

    # Copy data for each step
    for step_name in step_names:
        prefix = f"{execution_id}/{step_name}/"

        logger.info(
            f"Copying s3://{intermediate_bucket}/{prefix} "
            f"to s3://{output_bucket}/{prefix}"
        )

        # Check source has objects before copying
        resp = s3.list_objects_v2(
            Bucket=intermediate_bucket,
            Prefix=prefix,
            MaxKeys=1,
        )
        if resp.get("KeyCount", 0) == 0:
            logger.warning(
                f"No objects found for step {step_name} — skipping",
                extra={"source_prefix": prefix},
            )
            continue

        try:
            copied = copy_objects(intermediate_bucket, output_bucket, prefix)
            logger.info(
                f"Successfully copied step {step_name}",
                extra={"objects_copied": copied},
            )
        except Exception as e:
            logger.error(
                f"Failed to copy data for step {step_name}",
                extra={"error": str(e)},
            )
            sys.exit(1)

    logger.info("All data copied successfully")


if __name__ == "__main__":
    main()
