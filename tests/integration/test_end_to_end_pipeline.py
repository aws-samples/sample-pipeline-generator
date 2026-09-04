# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: MIT-0

import pytest
import json
import time
import os
import logging

logger = logging.getLogger(__name__)
logging.basicConfig(
    level=logging.INFO, format="%(asctime)s %(levelname)s %(message)s"
)

TEST_SOURCE_PREFIX = "test-data/input/sensor-batch"


@pytest.fixture
def sfn_payload():
    return json.dumps({})


def get_execution_status(sfn_client, execution_arn):
    """Get execution status directly from Step Functions."""
    return sfn_client.describe_execution(executionArn=execution_arn)["status"]


def _bucket_name_from_sfn_arn(sfn_arn, bucket_type):
    """Derive S3 bucket name from SFN ARN using naming convention: <pipeline>-<env>-<type>-<account_id>."""
    parts = sfn_arn.split(":")
    account_id = parts[4]
    sfn_name = parts[-1]  # <pipeline_name>-<env>
    return f"{sfn_name}-{bucket_type}-{account_id}"


TEST_DATA_DIR = os.path.join(
    os.path.dirname(__file__),
    "..",
    "..",
    "examples",
    "end-to-end",
    "code",
    "test-data",
)


def _upload_test_data(s3_client, source_bucket):
    """Upload local test data to the source bucket so the pipeline has something to process."""
    logger.info(
        f"Uploading test data from {TEST_DATA_DIR} to s3://{source_bucket}/{TEST_SOURCE_PREFIX}"
    )
    for root, _dirs, files in os.walk(
        os.path.join(TEST_DATA_DIR, "input", "sensor-batch")
    ):
        for filename in files:
            local_path = os.path.join(root, filename)
            rel_path = os.path.relpath(local_path, TEST_DATA_DIR)
            key = f"test-data/{rel_path}"
            logger.info(f"Uploading {key}")
            s3_client.upload_file(local_path, source_bucket, key)


def _cleanup_test_data(s3_client, bucket, prefix):
    """Delete all objects under a prefix (best-effort cleanup)."""
    paginator = s3_client.get_paginator("list_objects_v2")
    for page in paginator.paginate(Bucket=bucket, Prefix=prefix):
        objects = [{"Key": obj["Key"]} for obj in page.get("Contents", [])]
        if objects:
            s3_client.delete_objects(
                Bucket=bucket, Delete={"Objects": objects}
            )
            logger.info(
                f"Cleaned up {len(objects)} object(s) from s3://{bucket}/{prefix}"
            )


def _verify_copy_to_output(
    s3_client, intermediate_bucket, output_bucket, execution_name, step_names
):
    """Verify that data was copied from intermediate to output for each step."""
    for step_name in step_names:
        intermediate_prefix = f"{execution_name}/{step_name}/"
        output_prefix = f"{execution_name}/{step_name}/"

        # List objects in intermediate
        intermediate_resp = s3_client.list_objects_v2(
            Bucket=intermediate_bucket, Prefix=intermediate_prefix, MaxKeys=1
        )
        intermediate_count = intermediate_resp.get("KeyCount", 0)
        logger.info(
            f"Intermediate bucket '{intermediate_bucket}/{intermediate_prefix}': {intermediate_count} object(s)"
        )

        assert intermediate_count > 0, (
            f"No objects found in intermediate bucket at {intermediate_bucket}/{intermediate_prefix} "
            f"— the batch step '{step_name}' did not produce output"
        )

        # List objects in output
        output_resp = s3_client.list_objects_v2(
            Bucket=output_bucket, Prefix=output_prefix, MaxKeys=1
        )
        output_count = output_resp.get("KeyCount", 0)
        logger.info(
            f"Output bucket '{output_bucket}/{output_prefix}': {output_count} object(s)"
        )

        assert output_count > 0, (
            f"No objects found in output bucket at {output_bucket}/{output_prefix} "
            f"— Copy-To-Output step failed to copy data for step '{step_name}'"
        )


def test_end_to_end_pipeline_execution(
    sfn_client, sfn_arn, sfn_payload, s3_client
):
    """Test that the end-to-end pipeline executes successfully.

    This pipeline exercises:
    1. ingest_raw_data (batch) — reads sensor data from source bucket
    2. validate_ingestion (lambda) — validates the ingested manifest
    3. split_workload (lambda) — produces chunks array for parallel block
    4. fan_out_processing (parallel) — transform_chunk (batch) + score_chunk (lambda)
    5. aggregate_results (batch, copy_to_target) — aggregates parallel outputs
    6. publish_report (lambda) — final reporting step

    Verifies end-to-end execution and that data is copied to the output bucket.
    """
    source_bucket = _bucket_name_from_sfn_arn(sfn_arn, "source")
    intermediate_bucket = _bucket_name_from_sfn_arn(sfn_arn, "intermediate")
    output_bucket = _bucket_name_from_sfn_arn(sfn_arn, "output")

    # Upload test data to source bucket
    _upload_test_data(s3_client, source_bucket)

    try:
        logger.info(f"Starting execution for state machine: {sfn_arn}")
        response = sfn_client.start_execution(
            stateMachineArn=sfn_arn, input=sfn_payload
        )
        execution_arn = response["executionArn"]
        execution_name = execution_arn.rsplit(":", 1)[-1]
        logger.info(f"Execution started: {execution_arn}")

        # Poll for completion (longer timeout for complex pipeline)
        status = None
        for i in range(90):
            status = get_execution_status(sfn_client, execution_arn)
            logger.info(f"Execution status (poll {i + 1}/90): {status}")
            if status in ["SUCCEEDED", "FAILED", "TIMED_OUT", "ABORTED"]:
                break
            time.sleep(10)

        assert status == "SUCCEEDED", f"Execution failed with status: {status}"

        # Verify data was copied from intermediate to output bucket
        # aggregate_results has copy_to_target=true
        _verify_copy_to_output(
            s3_client,
            intermediate_bucket,
            output_bucket,
            execution_name,
            ["aggregate_results"],
        )
    finally:
        # Clean up test data from source bucket
        _cleanup_test_data(s3_client, source_bucket, TEST_SOURCE_PREFIX)
