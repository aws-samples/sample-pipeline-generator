# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: MIT-0

"""Tests for transform_chunk step."""

import json
from unittest.mock import MagicMock, patch

import pytest

from main import _transform_record, main


class TestTransformRecord:
    """Tests for the _transform_record helper."""

    def test_transforms_jsonl_lines(self):
        raw = '{"id": 1}\n{"id": 2}\n'
        result = _transform_record(raw, "default")
        assert len(result) == 2
        assert result[0]["_transformed"] is True
        assert result[0]["_transform_config"] == "default"
        assert result[0]["id"] == 1

    def test_single_line(self):
        raw = '{"value": "test"}'
        result = _transform_record(raw, "custom")
        assert len(result) == 1
        assert result[0]["_transform_config"] == "custom"

    def test_non_json_falls_back_to_raw(self):
        raw = "not json at all"
        result = _transform_record(raw, "default")
        assert len(result) == 1
        assert result[0]["raw"] == "not json at all"
        assert result[0]["_transformed"] is True

    def test_empty_lines_skipped(self):
        raw = '{"a": 1}\n\n{"b": 2}\n\n'
        result = _transform_record(raw, "default")
        assert len(result) == 2

    def test_empty_string(self):
        result = _transform_record("", "default")
        # Empty string → no lines after strip/split filtering
        assert all(r.get("_transformed") is True for r in result)


class TestMain:
    """Tests for the batch main() entrypoint with mocked S3."""

    @pytest.fixture(autouse=True)
    def _env(self, monkeypatch):
        monkeypatch.setenv("STEP_NAME", "transform_chunk")
        monkeypatch.setenv("INTERMEDIATE_BUCKET", "test-intermediate")
        monkeypatch.setenv("SOURCE_BUCKET", "test-source")
        monkeypatch.setenv("SFN_EXECUTION_ID", "exec-001")
        monkeypatch.setenv("TRANSFORM_CONFIG", "default")
        monkeypatch.setenv(
            "MAP_ITEM",
            json.dumps({"chunk_id": 0, "object_keys": ["data/a.jsonl"]}),
        )
        monkeypatch.setenv("STEP_INGEST_RAW_DATA", "{}")
        monkeypatch.setenv("STEP_VALIDATE_INGESTION", "{}")
        monkeypatch.setenv("STEP_SPLIT_WORKLOAD", "{}")

    @patch("main.boto3")
    def test_transforms_and_writes_output(self, mock_boto3):
        mock_s3 = MagicMock()
        mock_boto3.client.return_value = mock_s3

        mock_s3.get_object.return_value = {
            "Body": MagicMock(
                read=lambda: b'{"id": 1}\n{"id": 2}\n', decode=None
            )
        }
        mock_s3.get_object.return_value["Body"].read = (
            lambda: b'{"id": 1}\n{"id": 2}\n'
        )

        main()

        # Should write transformed data + summary
        assert mock_s3.put_object.call_count == 2

        # Check summary
        summary_call = mock_s3.put_object.call_args_list[-1]
        summary = json.loads(summary_call[1]["Body"])
        assert summary["chunk_id"] == 0
        assert summary["total_objects"] == 1
        assert summary["transformed"] == 1
        assert summary["errors"] == 0

    @patch("main.boto3")
    def test_handles_s3_read_error(self, mock_boto3):
        mock_s3 = MagicMock()
        mock_boto3.client.return_value = mock_s3
        mock_s3.get_object.side_effect = Exception("access denied")

        main()

        # Should still write summary with error status
        summary_call = mock_s3.put_object.call_args_list[-1]
        summary = json.loads(summary_call[1]["Body"])
        assert summary["errors"] == 1
        assert summary["transformed"] == 0

    @patch("main.boto3")
    def test_empty_chunk(self, mock_boto3, monkeypatch):
        monkeypatch.setenv(
            "MAP_ITEM", json.dumps({"chunk_id": 3, "object_keys": []})
        )
        mock_s3 = MagicMock()
        mock_boto3.client.return_value = mock_s3

        main()

        summary_call = mock_s3.put_object.call_args_list[-1]
        summary = json.loads(summary_call[1]["Body"])
        assert summary["chunk_id"] == 3
        assert summary["total_objects"] == 0

    @patch("main.boto3")
    def test_info_logs_do_not_contain_raw_step_or_execution_input(
        self, mock_boto3, monkeypatch, caplog
    ):
        # STEP_* values and EXECUTION_INPUT contents must NEVER be emitted at
        # INFO — copying this template into production would otherwise spill
        # upstream, potentially caller-supplied, data into CloudWatch Logs.
        monkeypatch.setenv(
            "MAP_ITEM", json.dumps({"chunk_id": 0, "object_keys": []})
        )
        mock_s3 = MagicMock()
        mock_boto3.client.return_value = mock_s3

        sensitive_step_value = "SENSITIVE-STEP-VALUE-8f2a"
        sensitive_input_value = "SENSITIVE-EXEC-INPUT-VALUE-1c3e"
        monkeypatch.setenv(
            "STEP_INGEST_RAW_DATA",
            json.dumps({"token": sensitive_step_value}),
        )
        monkeypatch.setenv(
            "EXECUTION_INPUT", json.dumps({"secret": sensitive_input_value})
        )

        with caplog.at_level("INFO"):
            main()

        # Powertools stores structured kwargs as extra record attributes, so
        # assert against the message AND those attributes — not getMessage()
        # alone, which would ignore a leaked value= / execution_input= field.
        info_blob = " ".join(
            f"{r.getMessage()} {r.__dict__}"
            for r in caplog.records
            if r.levelname == "INFO"
        )
        assert sensitive_step_value not in info_blob
        assert sensitive_input_value not in info_blob
