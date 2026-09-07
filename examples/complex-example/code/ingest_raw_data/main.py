# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: MIT-0

"""Batch step: Ingest raw data from the source bucket.

Reads all objects under the discovered source path, validates basic structure,
and writes a consolidated manifest to the intermediate bucket.

Environment variables (set by pipeline):
    STEP_NAME, SOURCE_BUCKET, INTERMEDIATE_BUCKET, SSM_PARAMS_PREFIX,
    SECRETS_PREFIX, SFN_EXECUTION_ID, SOURCE_PREFIX, SOURCE_SYSTEM,
    INGESTION_MODE
"""

import json
import os

import boto3
from aws_lambda_powertools import Logger

logger = Logger(service="complex-example-ingest-raw-data")
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
    source_prefix = os.environ.get("SOURCE_PREFIX", "")
    source_system = os.environ.get("SOURCE_SYSTEM", "default")
    ingestion_mode = os.environ.get("INGESTION_MODE", "full")

    # Verify: first step should have no STEP_ env vars from previous steps
    prev_step_vars = {
        k: v
        for k, v in os.environ.items()
        if k.startswith("STEP_") and k != "STEP_NAME"
    }
    if prev_step_vars:
        logger.warning(
            "Unexpected previous step variables found",
            prev_step_vars=list(prev_step_vars.keys()),
        )
    else:
        logger.info(
            "Verified: no previous step outputs (first step in pipeline)"
        )

    logger.info(
        "Starting ingestion",
        step_name=step_name,
        source_system=source_system,
        ingestion_mode=ingestion_mode,
        source=f"s3://{source_bucket}/{source_prefix}",
    )

    s3 = boto3.client("s3")

    # List all objects under the source prefix
    paginator = s3.get_paginator("list_objects_v2")
    ingested_objects = []

    for page in paginator.paginate(Bucket=source_bucket, Prefix=source_prefix):
        for obj in page.get("Contents", []):
            ingested_objects.append(
                {
                    "key": obj["Key"],
                    "size": obj["Size"],
                    "last_modified": obj["LastModified"].isoformat(),
                    "source_system": source_system,
                }
            )
            logger.info("Ingested object", key=obj["Key"], size=obj["Size"])

    if not ingested_objects:
        raise RuntimeError(
            f"No objects found at s3://{source_bucket}/{source_prefix}"
        )

    # Write manifest to intermediate bucket
    manifest = {
        "source_system": source_system,
        "ingestion_mode": ingestion_mode,
        "total_objects": len(ingested_objects),
        "total_size_bytes": sum(o["size"] for o in ingested_objects),
        "objects": ingested_objects,
    }

    manifest_key = f"{sfn_execution_id}/{step_name}/manifest.json"
    s3.put_object(
        Bucket=intermediate_bucket,
        Key=manifest_key,
        Body=json.dumps(manifest),
        ContentType="application/json",
    )

    logger.info(
        "Ingestion complete",
        total_objects=len(ingested_objects),
        manifest=f"s3://{intermediate_bucket}/{manifest_key}",
    )


if __name__ == "__main__":
    main()
