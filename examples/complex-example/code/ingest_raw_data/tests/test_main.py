# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: MIT-0

"""Tests for ingest_raw_data step."""

import contextlib
import json
from datetime import datetime, timezone
from unittest.mock import MagicMock, patch

import pytest

from main import main


class TestMain:
    """Tests for the batch main() entrypoint with mocked S3."""

    @pytest.fixture(autouse=True)
    def _env(self, monkeypatch):
        monkeypatch.setenv("STEP_NAME", "ingest_raw_data")
        monkeypatch.setenv("INTERMEDIATE_BUCKET", "test-intermediate")
        monkeypatch.setenv("SOURCE_BUCKET", "test-source")
        monkeypatch.setenv("SFN_EXECUTION_ID", "exec-001")
        monkeypatch.setenv("SOURCE_PREFIX", "sensor-batch/batch-001")
        monkeypatch.setenv("SOURCE_SYSTEM", "test-system")
        monkeypatch.setenv("INGESTION_MODE", "full")

    @patch("main.boto3")
    def test_ingests_objects_and_writes_manifest(self, mock_boto3):
        mock_s3 = MagicMock()
        mock_boto3.client.return_value = mock_s3

        now = datetime.now(timezone.utc)
        mock_s3.get_paginator.return_value.paginate.return_value = [
            {
                "Contents": [
                    {
                        "Key": "sensor-batch/batch-001/events.jsonl",
                        "Size": 1024,
                        "LastModified": now,
                    },
                    {
                        "Key": "sensor-batch/batch-001/telemetry.jsonl",
                        "Size": 2048,
                        "LastModified": now,
                    },
                ]
            }
        ]

        main()

        mock_s3.put_object.assert_called_once()
        call_kwargs = mock_s3.put_object.call_args[1]
        assert call_kwargs["Bucket"] == "test-intermediate"
        assert "exec-001/ingest_raw_data/manifest.json" == call_kwargs["Key"]

        manifest = json.loads(call_kwargs["Body"])
        assert manifest["source_system"] == "test-system"
        assert manifest["ingestion_mode"] == "full"
        assert manifest["total_objects"] == 2
        assert manifest["total_size_bytes"] == 3072

    @patch("main.boto3")
    def test_raises_on_empty_source(self, mock_boto3):
        mock_s3 = MagicMock()
        mock_boto3.client.return_value = mock_s3
        mock_s3.get_paginator.return_value.paginate.return_value = [
            {"Contents": []}
        ]

        with pytest.raises(RuntimeError, match="No objects found"):
            main()

    @patch("main.boto3")
    def test_raises_on_missing_contents(self, mock_boto3):
        mock_s3 = MagicMock()
        mock_boto3.client.return_value = mock_s3
        mock_s3.get_paginator.return_value.paginate.return_value = [{}]

        with pytest.raises(RuntimeError, match="No objects found"):
            main()

    @patch("main.boto3")
    def test_default_env_values(self, mock_boto3, monkeypatch):
        monkeypatch.delenv("SOURCE_SYSTEM", raising=False)
        monkeypatch.delenv("INGESTION_MODE", raising=False)

        mock_s3 = MagicMock()
        mock_boto3.client.return_value = mock_s3

        now = datetime.now(timezone.utc)
        mock_s3.get_paginator.return_value.paginate.return_value = [
            {
                "Contents": [
                    {
                        "Key": "data/file.jsonl",
                        "Size": 100,
                        "LastModified": now,
                    }
                ]
            }
        ]

        main()

        call_kwargs = mock_s3.put_object.call_args[1]
        manifest = json.loads(call_kwargs["Body"])
        assert manifest["source_system"] == "default"
        assert manifest["ingestion_mode"] == "full"

    @patch("main.boto3")
    def test_multi_page_pagination(self, mock_boto3):
        mock_s3 = MagicMock()
        mock_boto3.client.return_value = mock_s3

        now = datetime.now(timezone.utc)
        mock_s3.get_paginator.return_value.paginate.return_value = [
            {
                "Contents": [
                    {"Key": "page1/a.jsonl", "Size": 100, "LastModified": now}
                ]
            },
            {
                "Contents": [
                    {"Key": "page2/b.jsonl", "Size": 200, "LastModified": now}
                ]
            },
        ]

        main()

        call_kwargs = mock_s3.put_object.call_args[1]
        manifest = json.loads(call_kwargs["Body"])
        assert manifest["total_objects"] == 2
        assert manifest["total_size_bytes"] == 300

    @patch("main.boto3")
    def test_info_logs_do_not_contain_raw_step_or_execution_input(
        self, mock_boto3, monkeypatch, caplog
    ):
        # STEP_* values and EXECUTION_INPUT contents must NEVER be emitted at
        # INFO — copying this template into production would otherwise spill
        # upstream, potentially caller-supplied, data into CloudWatch Logs.
        mock_boto3.client.return_value = MagicMock()
        sensitive_step_value = "SENSITIVE-STEP-VALUE-8f2a"
        sensitive_input_value = "SENSITIVE-EXEC-INPUT-VALUE-1c3e"
        monkeypatch.setenv(
            "STEP_INGEST_RAW_DATA",
            json.dumps({"token": sensitive_step_value}),
        )
        monkeypatch.setenv(
            "EXECUTION_INPUT", json.dumps({"secret": sensitive_input_value})
        )

        with caplog.at_level("INFO"), contextlib.suppress(Exception):
            # The logging block runs before any S3 work; tolerate downstream
            # errors from incomplete mocks and assert only on emitted logs.
            main()

        # Powertools stores structured kwargs as extra record attributes, so
        # assert against the message AND those attributes — not getMessage()
        # alone, which would ignore a leaked value= / execution_input= field.
        info_records = [r for r in caplog.records if r.levelname == "INFO"]
        info_blob = " ".join(
            f"{r.getMessage()} {r.__dict__}" for r in info_records
        )
        assert (
            info_records
        ), "no INFO logs captured — assertion would be vacuous"
        assert sensitive_step_value not in info_blob
        assert sensitive_input_value not in info_blob
