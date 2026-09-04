# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: MIT-0

import pytest
import json
import time
import logging

logger = logging.getLogger(__name__)
logging.basicConfig(
    level=logging.INFO, format="%(asctime)s %(levelname)s %(message)s"
)


@pytest.fixture
def sfn_payload():
    return json.dumps({"inputs": {}})


def _bucket_name_from_sfn_arn(sfn_arn, bucket_type):
    """Derive S3 bucket name from SFN ARN using naming convention: <pipeline>-<env>-<type>-<account_id>."""
    parts = sfn_arn.split(":")
    account_id = parts[4]
    sfn_name = parts[-1]  # <pipeline_name>-<env>
    return f"{sfn_name}-{bucket_type}-{account_id}"


def get_execution_status(sfn_client, execution_arn):
    """Get execution status directly from Step Functions."""
    return sfn_client.describe_execution(executionArn=execution_arn)["status"]


def _cleanup_execution_data(s3_client, bucket, execution_name):
    """Delete all objects under the execution prefix (best-effort cleanup)."""
    paginator = s3_client.get_paginator("list_objects_v2")
    prefix = f"{execution_name}/"
    for page in paginator.paginate(Bucket=bucket, Prefix=prefix):
        objects = [{"Key": obj["Key"]} for obj in page.get("Contents", [])]
        if objects:
            s3_client.delete_objects(
                Bucket=bucket, Delete={"Objects": objects}
            )
            logger.info(
                f"Cleaned up {len(objects)} object(s) from s3://{bucket}/{prefix}"
            )


def _verify_prepare_data_output(
    s3_client, intermediate_bucket, execution_name
):
    """Verify that prepare_data wrote subdirectories to the intermediate bucket."""
    prefix = f"{execution_name}/prepare_data/"
    response = s3_client.list_objects_v2(
        Bucket=intermediate_bucket, Prefix=prefix
    )
    count = response.get("KeyCount", 0)
    logger.info(
        f"Intermediate bucket '{intermediate_bucket}/{prefix}': {count} object(s)"
    )
    assert count > 0, (
        f"No objects found in intermediate bucket at {intermediate_bucket}/{prefix} "
        f"— the 'prepare_data' step did not produce output"
    )


def _verify_processing_output(s3_client, intermediate_bucket, execution_name):
    """Verify that process_item wrote marker files to the intermediate bucket."""
    prefix = f"{execution_name}/process_item/"
    response = s3_client.list_objects_v2(
        Bucket=intermediate_bucket, Prefix=prefix
    )
    count = response.get("KeyCount", 0)
    logger.info(
        f"Intermediate bucket '{intermediate_bucket}/{prefix}': {count} object(s)"
    )
    assert count > 0, (
        f"No objects found in intermediate bucket at {intermediate_bucket}/{prefix} "
        f"— the parallel step 'process_item' did not produce output"
    )


def test_s3_parallel_from_step_pipeline_execution(
    sfn_client, sfn_arn, sfn_payload, s3_client
):
    """Test that the s3-parallel-from-step pipeline executes successfully.

    This pipeline tests the `from_step` option for S3 discovery:
    1. prepare_data writes subdirectories to intermediate bucket
    2. discover_sources validates the written data
    3. The parallel block uses `from_step: prepare_data` to discover
       directories from prepare_data's output (not the immediately
       preceding step)
    4. process_item runs for each discovered directory
    """
    intermediate_bucket = _bucket_name_from_sfn_arn(sfn_arn, "intermediate")

    logger.info(f"Starting execution for state machine: {sfn_arn}")
    response = sfn_client.start_execution(
        stateMachineArn=sfn_arn, input=sfn_payload
    )
    execution_arn = response["executionArn"]
    execution_name = execution_arn.rsplit(":", 1)[-1]
    logger.info(f"Execution started: {execution_arn}")

    try:
        # Poll for completion
        status = None
        for i in range(60):
            status = get_execution_status(sfn_client, execution_arn)
            logger.info(f"Execution status (poll {i + 1}/60): {status}")
            if status in ["SUCCEEDED", "FAILED", "TIMED_OUT", "ABORTED"]:
                break
            time.sleep(10)

        assert status == "SUCCEEDED", f"Execution failed with status: {status}"

        # Verify prepare_data wrote subdirectories
        _verify_prepare_data_output(
            s3_client, intermediate_bucket, execution_name
        )

        # process_item output implies discover_sources succeeded upstream
        _verify_processing_output(
            s3_client, intermediate_bucket, execution_name
        )
    finally:
        # Clean up execution data from intermediate bucket
        _cleanup_execution_data(s3_client, intermediate_bucket, execution_name)
