# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: MIT-0

import json
import os

import boto3
from aws_lambda_powertools import Logger

## This configuration allows the logging aggregation
logger = Logger(service="my-pipeline-simple_step")
PIPELINE_NAME = os.environ.get("PIPELINE_NAME", "unknown")
STEP_NAME = os.environ.get("STEP_NAME", "unknown")
SFN_EXECUTION_ID = os.environ["SFN_EXECUTION_ID"]

logger.append_keys(step_name=STEP_NAME)
logger.append_keys(run_id=SFN_EXECUTION_ID)
logger.append_keys(pipeline_name=PIPELINE_NAME)


def main():
    step_name = STEP_NAME
    sfn_execution_id = SFN_EXECUTION_ID

    intermediate_bucket = os.environ["INTERMEDIATE_BUCKET"]
    input_bucket = os.environ["SOURCE_BUCKET"]
    source_path = ""

    # Log only presence and size of STEP_* payloads at INFO; gate raw values
    # behind DEBUG so example steps do not spill upstream data into CloudWatch
    # Logs when copied into production. See the pipeline README security note.
    for key, value in os.environ.items():
        if key.startswith("STEP_") and key != "STEP_NAME":
            logger.info(
                "Previous step result present", key=key, size=len(value)
            )
            logger.debug("Previous step result value", key=key, value=value)

    # Load the StepFunction Execution Input. Do NOT log raw values at INFO —
    # execution input is caller-supplied and may contain sensitive data.
    execution_input = json.loads(os.environ.get("EXECUTION_INPUT", "{}"))
    if execution_input:
        logger.info(
            "Execution input received",
            keys=list(execution_input.keys()),
            size_bytes=len(json.dumps(execution_input)),
        )
        logger.debug("Execution input value", execution_input=execution_input)

    try:
        source_path = execution_input["inputs"]["root_prefix"]
    except KeyError:
        logger.info(
            f"Falling back to top level for source bucket {input_bucket}"
        )

    logger.info(
        "Starting step",
        step_name=step_name,
        execution_id=sfn_execution_id,
        source=f"s3://{input_bucket}/{source_path}",
    )

    s3 = boto3.client("s3")

    # 1. Read from source bucket
    response = s3.list_objects_v2(Bucket=input_bucket, Prefix=source_path)
    contents = response.get("Contents", [])
    if not contents:
        raise RuntimeError(
            f"No objects found at s3://{input_bucket}/{source_path}"
        )

    source_data = []
    for obj in contents:
        s3.get_object(Bucket=input_bucket, Key=obj["Key"])["Body"].read()
        source_data.append({"key": obj["Key"], "size": obj["Size"]})
        logger.info("Read source object", key=obj["Key"], size=obj["Size"])

    # 2. Write to intermediate bucket
    for dir in ["result1", "result2"]:
        output_key = f"{sfn_execution_id}/{step_name}/{dir}/result.json"
        result = {
            "source_path": source_path,
            "files_read": len(source_data),
            "objects": source_data,
        }
        s3.put_object(
            Bucket=intermediate_bucket,
            Key=output_key,
            Body=json.dumps(result),
            ContentType="application/json",
        )
        logger.info("Wrote result", bucket=intermediate_bucket, key=output_key)

        # 3. Verify write by reading back
        verify = (
            s3.get_object(Bucket=intermediate_bucket, Key=output_key)["Body"]
            .read()
            .decode()
        )
        assert json.loads(verify) == result, "Write verification failed"
        logger.info("Write verification passed")


if __name__ == "__main__":
    main()
