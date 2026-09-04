# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: MIT-0

from moto import mock_aws
import boto3
import sys
import os
import pytest

sys.path.insert(0, os.path.dirname(os.path.dirname(__file__)))
from parallel_block_initialization.index import handler


INTERMEDIATE_BUCKET = "intermediate-bucket"
SOURCE_BUCKET = "source-bucket"


@pytest.fixture(autouse=True)
def mock_aws_env():
    """Defaults for every test — region + INTERMEDIATE_BUCKET.

    Individual tests override or delete env vars to exercise different paths.
    """
    os.environ["AWS_DEFAULT_REGION"] = "us-east-1"
    os.environ["INTERMEDIATE_BUCKET"] = INTERMEDIATE_BUCKET
    os.environ.pop("SOURCE_BUCKET", None)
    yield
    os.environ.pop("AWS_DEFAULT_REGION", None)
    os.environ.pop("INTERMEDIATE_BUCKET", None)
    os.environ.pop("SOURCE_BUCKET", None)


class MockLambdaContext:
    def __init__(self):
        self.function_name = "test-function"
        self.memory_limit_in_mb = 128
        self.invoked_function_arn = (
            "arn:aws:lambda:us-east-1:123456789012:function:test-function"
        )
        self.aws_request_id = "test-request-id"


def _base_event(**overrides):
    """Minimal event matching what parallel_block_init_step.json.tpl injects."""
    event = {
        "SFN_EXECUTION_ID": "exec-123",
        "STEP_NAME": "Parallel-Block-Initialization",
    }
    event.update(overrides)
    return event


# --- s3 type tests (no from_step, no previous step — first step in pipeline) ---


@mock_aws
def test_s3_first_step_uses_source_bucket():
    """When parallel is the first step and SOURCE_BUCKET env var is set,
    uses the source bucket with root_prefix from the execution payload."""
    os.environ["SOURCE_BUCKET"] = SOURCE_BUCKET

    s3 = boto3.client("s3", region_name="us-east-1")
    s3.create_bucket(Bucket=SOURCE_BUCKET)

    s3.put_object(Bucket=SOURCE_BUCKET, Key="root/dir1/file.txt", Body=b"test")
    s3.put_object(Bucket=SOURCE_BUCKET, Key="root/dir2/file.txt", Body=b"test")
    s3.put_object(Bucket=SOURCE_BUCKET, Key="root/dir3/file.txt", Body=b"test")

    event = _base_event(
        inputs={"type": "s3", "root_prefix": "root/"},
        STEP_NAME="test-step",
    )

    result = handler(event, MockLambdaContext())

    assert result["statusCode"] == 200
    assert result["resolved_bucket"] == SOURCE_BUCKET
    assert len(result["source_paths"]) == 3
    assert "root/dir1/" in result["source_paths"]
    assert "root/dir2/" in result["source_paths"]
    assert "root/dir3/" in result["source_paths"]


@mock_aws
def test_s3_first_step_falls_back_to_intermediate_when_no_source_bucket():
    """When parallel is the first step and SOURCE_BUCKET env var is NOT set,
    falls back to intermediate bucket."""
    s3 = boto3.client("s3", region_name="us-east-1")
    s3.create_bucket(Bucket=INTERMEDIATE_BUCKET)

    s3.put_object(
        Bucket=INTERMEDIATE_BUCKET, Key="root/dir1/file.txt", Body=b"test"
    )

    event = _base_event(
        inputs={"type": "s3", "root_prefix": "root/"},
        STEP_NAME="test-step",
    )

    result = handler(event, MockLambdaContext())

    assert result["statusCode"] == 200
    assert result["resolved_bucket"] == INTERMEDIATE_BUCKET
    assert len(result["source_paths"]) == 1
    assert "root/dir1/" in result["source_paths"]


def test_s3_first_step_no_root_prefix_raises():
    event = _base_event(
        inputs={"type": "s3"},
        STEP_NAME="test-step",
    )

    with pytest.raises(
        ValueError,
        match="root_prefix is required when the parallel block is the first step",
    ):
        handler(event, MockLambdaContext())


# --- s3 type tests (no from_step, has previous step — defaults to intermediate) ---


@mock_aws
def test_s3_defaults_to_previous_step_on_intermediate():
    """When there is a previous compute step, S3 discovery always uses
    intermediate bucket at <execution_id>/<previous_step>/."""
    s3 = boto3.client("s3", region_name="us-east-1")
    s3.create_bucket(Bucket=INTERMEDIATE_BUCKET)

    s3.put_object(
        Bucket=INTERMEDIATE_BUCKET,
        Key="exec-123/ingest_raw_data/batch-a/file.txt",
        Body=b"test",
    )
    s3.put_object(
        Bucket=INTERMEDIATE_BUCKET,
        Key="exec-123/ingest_raw_data/batch-b/file.txt",
        Body=b"test",
    )

    event = _base_event(
        inputs={"type": "s3"},
        STEP_NAME="test-step",
        previous_step="ingest_raw_data",
    )

    result = handler(event, MockLambdaContext())

    assert result["statusCode"] == 200
    assert result["resolved_bucket"] == INTERMEDIATE_BUCKET
    assert len(result["source_paths"]) == 2
    assert "exec-123/ingest_raw_data/batch-a/" in result["source_paths"]
    assert "exec-123/ingest_raw_data/batch-b/" in result["source_paths"]


@mock_aws
def test_s3_previous_step_ignores_source_bucket_env():
    """When previous_step is present, SOURCE_BUCKET env var is ignored —
    intermediate bucket is always used."""
    os.environ["SOURCE_BUCKET"] = SOURCE_BUCKET

    s3 = boto3.client("s3", region_name="us-east-1")
    s3.create_bucket(Bucket=INTERMEDIATE_BUCKET)

    s3.put_object(
        Bucket=INTERMEDIATE_BUCKET,
        Key="exec-123/step_a/dir1/file.txt",
        Body=b"test",
    )

    event = _base_event(
        inputs={
            "type": "s3",
            "root_prefix": "should-be-ignored/",
        },
        STEP_NAME="test-step",
        previous_step="step_a",
    )

    result = handler(event, MockLambdaContext())

    # Uses intermediate bucket, not the source bucket
    assert result["resolved_bucket"] == INTERMEDIATE_BUCKET
    assert result["source_paths"] == ["exec-123/step_a/dir1/"]


@mock_aws
def test_s3_no_directories():
    os.environ["SOURCE_BUCKET"] = "empty-bucket"

    s3 = boto3.client("s3", region_name="us-east-1")
    s3.create_bucket(Bucket="empty-bucket")

    event = _base_event(
        inputs={"type": "s3", "root_prefix": "empty/"},
        STEP_NAME="test-step",
    )

    with pytest.raises(
        Exception, match="No directories found in S3 discovery"
    ):
        handler(event, MockLambdaContext())


@mock_aws
def test_s3_bucket_not_found():
    os.environ["SOURCE_BUCKET"] = "nonexistent-bucket"

    event = _base_event(
        inputs={"type": "s3", "root_prefix": "root/"},
        STEP_NAME="test-step",
    )

    with pytest.raises(Exception, match="NoSuchBucket|does not exist"):
        handler(event, MockLambdaContext())


# --- s3 type with from_step (reads from intermediate bucket) ---


@mock_aws
def test_s3_from_step_uses_intermediate_bucket():
    s3 = boto3.client("s3", region_name="us-east-1")
    s3.create_bucket(Bucket=INTERMEDIATE_BUCKET)

    s3.put_object(
        Bucket=INTERMEDIATE_BUCKET,
        Key="exec-123/step_2/batch-a/file.txt",
        Body=b"test",
    )
    s3.put_object(
        Bucket=INTERMEDIATE_BUCKET,
        Key="exec-123/step_2/batch-b/file.txt",
        Body=b"test",
    )

    event = _base_event(
        inputs={"type": "s3", "from_step": "step_2"},
        STEP_NAME="test-step",
    )

    result = handler(event, MockLambdaContext())

    assert result["statusCode"] == 200
    assert result["resolved_bucket"] == INTERMEDIATE_BUCKET
    assert len(result["source_paths"]) == 2


@mock_aws
def test_s3_empty_root_prefix_discovers_top_level():
    """When root_prefix is empty, discovers top-level directories in the bucket."""
    os.environ["SOURCE_BUCKET"] = SOURCE_BUCKET

    s3 = boto3.client("s3", region_name="us-east-1")
    s3.create_bucket(Bucket=SOURCE_BUCKET)

    s3.put_object(Bucket=SOURCE_BUCKET, Key="dir-a/file.txt", Body=b"test")
    s3.put_object(Bucket=SOURCE_BUCKET, Key="dir-b/file.txt", Body=b"test")

    event = _base_event(
        inputs={"type": "s3", "root_prefix": ""},
        STEP_NAME="test-step",
    )

    result = handler(event, MockLambdaContext())

    assert result["statusCode"] == 200
    assert result["resolved_bucket"] == SOURCE_BUCKET
    assert len(result["source_paths"]) == 2
    assert "dir-a/" in result["source_paths"]
    assert "dir-b/" in result["source_paths"]


@mock_aws
def test_s3_from_step_without_root_prefix():
    """When from_step is used without root_prefix, discovery targets
    <exec_id>/<from_step>/ directly."""
    s3 = boto3.client("s3", region_name="us-east-1")
    s3.create_bucket(Bucket=INTERMEDIATE_BUCKET)

    s3.put_object(
        Bucket=INTERMEDIATE_BUCKET,
        Key="exec-123/step_2/batch-a/file.txt",
        Body=b"test",
    )
    s3.put_object(
        Bucket=INTERMEDIATE_BUCKET,
        Key="exec-123/step_2/batch-b/file.txt",
        Body=b"test",
    )

    event = _base_event(
        inputs={"type": "s3", "from_step": "step_2"},
        STEP_NAME="test-step",
    )

    result = handler(event, MockLambdaContext())

    assert result["statusCode"] == 200
    assert result["resolved_bucket"] == INTERMEDIATE_BUCKET
    assert len(result["source_paths"]) == 2
    assert "exec-123/step_2/batch-a/" in result["source_paths"]
    assert "exec-123/step_2/batch-b/" in result["source_paths"]


@mock_aws
def test_s3_from_step_with_custom_root_prefix():
    """When from_step is used with a root_prefix, the prefix is appended
    after the from_step directory: <exec_id>/<from_step>/<root_prefix>/."""
    s3 = boto3.client("s3", region_name="us-east-1")
    s3.create_bucket(Bucket=INTERMEDIATE_BUCKET)

    s3.put_object(
        Bucket=INTERMEDIATE_BUCKET,
        Key="exec-123/step_2/custom/prefix/dir1/file.txt",
        Body=b"test",
    )

    event = _base_event(
        inputs={
            "type": "s3",
            "from_step": "step_2",
            "root_prefix": "custom/prefix",
        },
        STEP_NAME="test-step",
    )

    result = handler(event, MockLambdaContext())

    assert result["statusCode"] == 200
    assert result["source_paths"] == ["exec-123/step_2/custom/prefix/dir1/"]


# --- custom type tests (no from_step — passthrough) ---


def test_custom_passthrough():
    event = _base_event(
        inputs={
            "type": "custom",
            "value": ["path/to/dir1/", "path/to/dir2/"],
        },
        STEP_NAME="test-step",
    )

    result = handler(event, MockLambdaContext())

    assert result["statusCode"] == 200
    assert result["source_paths"] == ["path/to/dir1/", "path/to/dir2/"]
    assert result["resolved_bucket"] is None


def test_custom_empty_list():
    event = _base_event(
        inputs={"type": "custom", "value": []},
        STEP_NAME="test-step",
    )

    result = handler(event, MockLambdaContext())

    assert result["statusCode"] == 200
    assert result["source_paths"] == []
    assert result["resolved_bucket"] is None


def test_custom_single_value_coerced_to_list():
    event = _base_event(
        inputs={"type": "custom", "value": "single-value"},
        STEP_NAME="test-step",
    )

    result = handler(event, MockLambdaContext())

    assert result["statusCode"] == 200
    assert result["source_paths"] == ["single-value"]


# --- custom type with from_step (reads from previous step output) ---


def test_custom_from_step_reads_field():
    event = _base_event(
        inputs={
            "type": "custom",
            "from_step": "split_workload",
            "field": "chunks",
        },
        STEP_NAME="test-step",
        from_step_result={
            "chunks": ["chunk-1", "chunk-2", "chunk-3"],
        },
    )

    result = handler(event, MockLambdaContext())

    assert result["statusCode"] == 200
    assert result["source_paths"] == ["chunk-1", "chunk-2", "chunk-3"]
    assert result["resolved_bucket"] is None


def test_custom_from_step_reads_nested_field():
    event = _base_event(
        inputs={
            "type": "custom",
            "from_step": "lambda_step",
            "field": "result.paths_after_lambda",
        },
        STEP_NAME="test-step",
        from_step_result={
            "result": {
                "paths_after_lambda": ["/path/a", "/path/b"],
            },
        },
    )

    result = handler(event, MockLambdaContext())

    assert result["statusCode"] == 200
    assert result["source_paths"] == ["/path/a", "/path/b"]


def test_custom_from_step_single_value_coerced():
    event = _base_event(
        inputs={
            "type": "custom",
            "from_step": "step_1",
            "field": "output",
        },
        STEP_NAME="test-step",
        from_step_result={"output": "single-item"},
    )

    result = handler(event, MockLambdaContext())

    assert result["statusCode"] == 200
    assert result["source_paths"] == ["single-item"]


def test_custom_from_step_missing_field_raises():
    event = _base_event(
        inputs={
            "type": "custom",
            "from_step": "step_1",
        },
        STEP_NAME="test-step",
        from_step_result={"data": []},
    )

    with pytest.raises(
        ValueError,
        match="field must be provided when using custom type with from_step",
    ):
        handler(event, MockLambdaContext())


def test_custom_from_step_missing_result_raises():
    event = _base_event(
        inputs={
            "type": "custom",
            "from_step": "step_1",
            "field": "chunks",
        },
        STEP_NAME="test-step",
    )

    with pytest.raises(
        ValueError,
        match="from_step_result not found in event",
    ):
        handler(event, MockLambdaContext())


# --- unsupported type ---


def test_unsupported_type_raises():
    event = _base_event(
        inputs={"type": "unknown"},
        STEP_NAME="test-step",
    )

    with pytest.raises(ValueError, match="Unsupported input type: unknown"):
        handler(event, MockLambdaContext())


# --- missing inputs ---


def test_missing_inputs_key_raises():
    event = {"SFN_EXECUTION_ID": "exec-123"}

    with pytest.raises(KeyError):
        handler(event, MockLambdaContext())


def test_missing_type_key_raises():
    event = _base_event(
        inputs={},
        STEP_NAME="test-step",
    )

    with pytest.raises(KeyError):
        handler(event, MockLambdaContext())
