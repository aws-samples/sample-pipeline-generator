# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: MIT-0

import os
import sys
import pytest

import boto3
from moto import mock_aws
from unittest.mock import patch

# Add parent dir to path so we can import copy_data
sys.path.insert(0, os.path.dirname(os.path.dirname(__file__)))

ENV_VARS = {
    "INTERMEDIATE_BUCKET": "test-intermediate",
    "OUTPUT_BUCKET": "test-output",
    "SFN_EXECUTION_ID": "exec-123",
    "SOURCE_STEP_NAMES": "step-a",
}


@pytest.fixture(autouse=True)
def set_env(monkeypatch):
    for k, v in ENV_VARS.items():
        monkeypatch.setenv(k, v)


@pytest.fixture
def s3_buckets():
    with mock_aws():
        s3 = boto3.client("s3", region_name="us-east-1")
        s3.create_bucket(Bucket="test-intermediate")
        s3.create_bucket(Bucket="test-output")
        with patch("copy_data.s3", s3):
            yield s3


def test_skips_when_no_objects(s3_buckets):
    """Should skip copy when source prefix is empty."""
    import copy_data

    copy_data.main()

    # Output bucket should remain empty
    resp = s3_buckets.list_objects_v2(Bucket="test-output")
    assert resp.get("KeyCount", 0) == 0


def test_copies_objects_when_they_exist(s3_buckets):
    """Should copy objects from intermediate to output bucket."""
    s3_buckets.put_object(
        Bucket="test-intermediate",
        Key="exec-123/step-a/file.txt",
        Body=b"data",
    )

    import copy_data

    copy_data.main()

    # Verify object exists in output bucket with same key
    resp = s3_buckets.get_object(
        Bucket="test-output", Key="exec-123/step-a/file.txt"
    )
    assert resp["Body"].read() == b"data"


def test_copies_multiple_objects(s3_buckets):
    """Should copy all objects under the step prefix."""
    s3_buckets.put_object(
        Bucket="test-intermediate",
        Key="exec-123/step-a/file1.txt",
        Body=b"one",
    )
    s3_buckets.put_object(
        Bucket="test-intermediate",
        Key="exec-123/step-a/subdir/file2.txt",
        Body=b"two",
    )

    import copy_data

    copy_data.main()

    resp = s3_buckets.list_objects_v2(
        Bucket="test-output", Prefix="exec-123/step-a/"
    )
    keys = [obj["Key"] for obj in resp.get("Contents", [])]
    assert "exec-123/step-a/file1.txt" in keys
    assert "exec-123/step-a/subdir/file2.txt" in keys


def test_exits_on_copy_failure(s3_buckets):
    """Should sys.exit(1) when a copy operation fails."""
    s3_buckets.put_object(
        Bucket="test-intermediate",
        Key="exec-123/step-a/file.txt",
        Body=b"data",
    )

    with patch(
        "copy_data.copy_objects", side_effect=Exception("S3 copy failed")
    ):
        import copy_data

        with pytest.raises(SystemExit) as exc:
            copy_data.main()
        assert exc.value.code == 1


def test_multiple_steps_copies_all(s3_buckets, monkeypatch):
    """Should copy each step independently."""
    monkeypatch.setenv("SOURCE_STEP_NAMES", "step-a,step-b")
    s3_buckets.put_object(
        Bucket="test-intermediate",
        Key="exec-123/step-a/f.txt",
        Body=b"a",
    )
    s3_buckets.put_object(
        Bucket="test-intermediate",
        Key="exec-123/step-b/f.txt",
        Body=b"b",
    )

    import copy_data

    copy_data.main()

    # Both steps should be in output
    resp_a = s3_buckets.get_object(
        Bucket="test-output", Key="exec-123/step-a/f.txt"
    )
    assert resp_a["Body"].read() == b"a"

    resp_b = s3_buckets.get_object(
        Bucket="test-output", Key="exec-123/step-b/f.txt"
    )
    assert resp_b["Body"].read() == b"b"


def test_multiple_steps_skips_empty(s3_buckets, monkeypatch):
    """Should copy step-a but skip step-b when step-b has no objects."""
    monkeypatch.setenv("SOURCE_STEP_NAMES", "step-a,step-b")
    s3_buckets.put_object(
        Bucket="test-intermediate",
        Key="exec-123/step-a/f.txt",
        Body=b"a",
    )

    import copy_data

    copy_data.main()

    # step-a copied
    resp = s3_buckets.get_object(
        Bucket="test-output", Key="exec-123/step-a/f.txt"
    )
    assert resp["Body"].read() == b"a"

    # step-b not present in output
    resp = s3_buckets.list_objects_v2(
        Bucket="test-output", Prefix="exec-123/step-b/"
    )
    assert resp.get("KeyCount", 0) == 0


def test_missing_env_var(monkeypatch):
    """Should raise KeyError when required env var is missing."""
    monkeypatch.delenv("INTERMEDIATE_BUCKET", raising=False)
    import copy_data

    with pytest.raises(KeyError):
        copy_data.main()


def test_copy_objects_returns_count(s3_buckets):
    """copy_objects should return the number of objects copied."""
    s3_buckets.put_object(
        Bucket="test-intermediate",
        Key="exec-123/step-a/a.txt",
        Body=b"a",
    )
    s3_buckets.put_object(
        Bucket="test-intermediate",
        Key="exec-123/step-a/b.txt",
        Body=b"b",
    )

    import copy_data

    count = copy_data.copy_objects(
        "test-intermediate", "test-output", "exec-123/step-a/"
    )
    assert count == 2
