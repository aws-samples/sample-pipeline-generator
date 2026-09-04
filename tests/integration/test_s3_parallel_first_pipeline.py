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

TEST_SOURCE_PREFIX = "test-data/input/parallel-data"


@pytest.fixture
def sfn_payload():
    return json.dumps(
        {
            "inputs": {
                "type": "s3",
                "root_prefix": TEST_SOURCE_PREFIX,
            }
        }
    )


def _bucket_name_from_sfn_arn(sfn_arn, bucket_type):
    """Derive S3 bucket name from SFN ARN using naming convention: <pipeline>-<env>-<type>-<account_id>."""
    parts = sfn_arn.split(":")
    account_id = parts[4]
    sfn_name = parts[-1]  # <pipeline_name>-<env>
    return f"{sfn_name}-{bucket_type}-{account_id}"


def _upload_test_data(s3_client, source_bucket):
    """Upload synthetic test data to the source bucket to simulate S3 discovery input."""
    logger.info(
        f"Uploading test data to s3://{source_bucket}/{TEST_SOURCE_PREFIX}"
    )
    subdirs = ["batch-a", "batch-b", "batch-c"]
    for subdir in subdirs:
        key = f"{TEST_SOURCE_PREFIX}/{subdir}/data.json"
        s3_client.put_object(
            Bucket=source_bucket,
            Key=key,
            Body=json.dumps({"batch": subdir, "status": "ready"}),
            ContentType="application/json",
        )
        logger.info(f"Uploaded {key}")


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


def get_execution_status(sfn_client, execution_arn):
    """Get execution status directly from Step Functions."""
    return sfn_client.describe_execution(executionArn=execution_arn)["status"]


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


def test_s3_parallel_first_pipeline_execution(
    sfn_client, sfn_arn, sfn_payload, s3_client
):
    """Test that the s3-parallel-first pipeline executes successfully.

    This pipeline has the parallel block as the first step. It discovers
    directories on the source bucket using root_prefix and fans out to
    process_item lambda for each discovered directory.
    """
    source_bucket = _bucket_name_from_sfn_arn(sfn_arn, "source")
    intermediate_bucket = _bucket_name_from_sfn_arn(sfn_arn, "intermediate")

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

        # Poll for completion
        status = None
        for i in range(60):
            status = get_execution_status(sfn_client, execution_arn)
            logger.info(f"Execution status (poll {i + 1}/60): {status}")
            if status in ["SUCCEEDED", "FAILED", "TIMED_OUT", "ABORTED"]:
                break
            time.sleep(10)

        assert status == "SUCCEEDED", f"Execution failed with status: {status}"

        # Verify process_item wrote output to intermediate bucket
        _verify_processing_output(
            s3_client, intermediate_bucket, execution_name
        )
    finally:
        # Clean up test data from source bucket
        _cleanup_test_data(s3_client, source_bucket, TEST_SOURCE_PREFIX)
