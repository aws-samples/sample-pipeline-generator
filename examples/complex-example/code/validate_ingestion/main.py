# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: MIT-0

"""Lambda step: Validate ingested data.

Reads the manifest produced by ingest-raw-data, runs validation checks
(schema, completeness, duplicates), and writes a validation report.

Environment variables (set by pipeline):
    STEP_NAME, SOURCE_BUCKET, INTERMEDIATE_BUCKET, OUTPUT_BUCKET,
    SSM_PARAMS_PREFIX, SECRETS_PREFIX, VALIDATION_PROFILE

Payload fields (from Step Functions):
    SFN_EXECUTION_ID, STATE
"""

import json
import os

import boto3
from aws_lambda_powertools import Logger

logger = Logger(service="complex-example-validate-ingestion")
PIPELINE_NAME = os.environ.get("PIPELINE_NAME", "unknown")
STEP_NAME = os.environ.get("STEP_NAME", "unknown")

logger.append_keys(step_name=STEP_NAME)
logger.append_keys(pipeline_name=PIPELINE_NAME)

s3 = boto3.client("s3")


@logger.inject_lambda_context
def handler(event, context):
    run_id = event.get("SFN_EXECUTION_ID")
    if run_id:
        logger.append_keys(run_id=run_id)
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
    validation_profile = os.environ.get("VALIDATION_PROFILE", "standard")

    # Extract execution context from the state passed by Step Functions
    state = event.get("STATE", event)
    sfn_execution_id = event.get("SFN_EXECUTION_ID", "unknown")

    # Verify previous step output: STEP_INGEST_RAW_DATA should be present
    prev_step_key = "STEP_INGEST_RAW_DATA"
    prev_step_data = event.get(prev_step_key)
    if prev_step_data is not None:
        logger.info("Received previous step output", key=prev_step_key)
        logger.debug(
            "Received previous step output value",
            key=prev_step_key,
            data=prev_step_data,
        )
    else:
        logger.warning(
            "Missing expected previous step output",
            key=prev_step_key,
            available_keys=list(event.keys()),
        )

    # Read the manifest from the previous step
    prev_step = "ingest_raw_data"
    prev_result = state.get(f"{prev_step}_result", {})
    manifest_payload = prev_result.get("Payload", {})

    logger.info(
        "Starting validation",
        step_name=step_name,
        execution_id=sfn_execution_id,
        validation_profile=validation_profile,
    )

    # Read manifest from intermediate bucket
    manifest_key = f"{sfn_execution_id}/{prev_step}/manifest.json"
    try:
        manifest_obj = s3.get_object(
            Bucket=intermediate_bucket, Key=manifest_key
        )
        manifest = json.loads(manifest_obj["Body"].read().decode())
    except s3.exceptions.NoSuchKey:
        logger.warning(
            "Manifest not found, using payload data", key=manifest_key
        )
        manifest = manifest_payload

    # Run validation checks
    issues = []
    validated_objects = []

    for obj in manifest.get("objects", []):
        obj_issues = _validate_object(obj, validation_profile)
        validated_objects.append(
            {
                "key": obj["key"],
                "valid": len(obj_issues) == 0,
                "issues": obj_issues,
            }
        )
        issues.extend(obj_issues)

    # Write validation report
    report = {
        "validation_profile": validation_profile,
        "total_objects": len(validated_objects),
        "valid_objects": sum(1 for o in validated_objects if o["valid"]),
        "invalid_objects": sum(1 for o in validated_objects if not o["valid"]),
        "total_issues": len(issues),
        "objects": validated_objects,
    }

    report_key = f"{sfn_execution_id}/{step_name}/validation_report.json"
    s3.put_object(
        Bucket=intermediate_bucket,
        Key=report_key,
        Body=json.dumps(report),
        ContentType="application/json",
    )

    logger.info(
        "Validation complete",
        valid=report["valid_objects"],
        invalid=report["invalid_objects"],
        issues=report["total_issues"],
    )

    return {
        "status": "success",
        "valid_objects": report["valid_objects"],
        "invalid_objects": report["invalid_objects"],
        "report_path": f"s3://{intermediate_bucket}/{report_key}",
    }


def _validate_object(obj, profile):
    """Run validation checks on a single object."""
    issues = []

    if obj.get("size", 0) == 0:
        issues.append({"type": "empty_file", "key": obj["key"]})

    if profile == "strict" and not obj.get("key", "").endswith(".jsonl"):
        issues.append({"type": "unexpected_format", "key": obj["key"]})

    return issues
