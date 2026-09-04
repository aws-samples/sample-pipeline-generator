# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: MIT-0

"""Tests for split_workload step."""

import json
from unittest.mock import MagicMock, patch

import pytest

from main import DEFAULT_CHUNK_SIZE, handler


def _fake_lambda_context():
    """Minimal fake Lambda context.

    Handlers here are decorated with ``@logger.inject_lambda_context``, which
    reads ``context.function_name`` / ``.memory_limit_in_mb`` / etc. before the
    handler body runs. Passing ``None`` raises AttributeError under current
    Powertools, so tests supply this stand-in.
    """
    context = MagicMock()
    context.function_name = "test"
    context.memory_limit_in_mb = 128
    context.invoked_function_arn = (
        "arn:aws:lambda:us-east-1:000000000000:function:test"
    )
    context.aws_request_id = "test-request-id"
    return context


class TestHandler:
    """Tests for the Lambda handler."""

    @pytest.fixture(autouse=True)
    def _env(self, monkeypatch):
        monkeypatch.setenv("STEP_NAME", "split_workload")
        monkeypatch.setenv("INTERMEDIATE_BUCKET", "test-intermediate")

    @patch("main.s3")
    def test_splits_objects_into_chunks(self, mock_s3):
        report = {
            "objects": [
                {"key": f"obj-{i}.jsonl", "valid": True} for i in range(5)
            ]
        }
        mock_s3.get_object.return_value = {
            "Body": MagicMock(read=lambda: json.dumps(report).encode())
        }

        event = {
            "SFN_EXECUTION_ID": "exec-001",
            "STEP_INGEST_RAW_DATA": "prev-data",
            "STEP_VALIDATE_INGESTION": "prev-data",
        }

        result = handler(event, _fake_lambda_context())

        assert result["status"] == "success"
        expected_chunks = 3  # ceil(5 / DEFAULT_CHUNK_SIZE=2)
        assert result["total_chunks"] == expected_chunks
        assert len(result["chunks"]) == expected_chunks

        # First chunk has 2 objects, last has 1
        assert result["chunks"][0]["object_count"] == 2
        assert result["chunks"][-1]["object_count"] == 1

        # Chunk IDs are sequential
        assert [c["chunk_id"] for c in result["chunks"]] == [0, 1, 2]

    @patch("main.s3")
    def test_filters_invalid_objects(self, mock_s3):
        report = {
            "objects": [
                {"key": "valid.jsonl", "valid": True},
                {"key": "invalid.jsonl", "valid": False},
                {"key": "also-valid.jsonl", "valid": True},
            ]
        }
        mock_s3.get_object.return_value = {
            "Body": MagicMock(read=lambda: json.dumps(report).encode())
        }

        event = {"SFN_EXECUTION_ID": "exec-002"}
        result = handler(event, _fake_lambda_context())

        # Only 2 valid objects → 1 chunk of size 2
        assert result["total_chunks"] == 1
        assert result["chunks"][0]["object_count"] == 2
        all_keys = result["chunks"][0]["object_keys"]
        assert "invalid.jsonl" not in all_keys

    @patch("main.s3")
    def test_empty_report_returns_no_chunks(self, mock_s3):
        report = {"objects": []}
        mock_s3.get_object.return_value = {
            "Body": MagicMock(read=lambda: json.dumps(report).encode())
        }

        event = {"SFN_EXECUTION_ID": "exec-003"}
        result = handler(event, _fake_lambda_context())

        assert result["status"] == "success"
        assert result["chunks"] == []
        assert result["total_chunks"] == 0

    @patch("main.s3")
    def test_all_invalid_returns_no_chunks(self, mock_s3):
        report = {
            "objects": [
                {"key": "bad1.jsonl", "valid": False},
                {"key": "bad2.jsonl", "valid": False},
            ]
        }
        mock_s3.get_object.return_value = {
            "Body": MagicMock(read=lambda: json.dumps(report).encode())
        }

        event = {"SFN_EXECUTION_ID": "exec-004"}
        result = handler(event, _fake_lambda_context())

        assert result["chunks"] == []
        assert result["total_chunks"] == 0

    @patch("main.s3")
    def test_single_object_produces_single_chunk(self, mock_s3):
        report = {"objects": [{"key": "only.jsonl", "valid": True}]}
        mock_s3.get_object.return_value = {
            "Body": MagicMock(read=lambda: json.dumps(report).encode())
        }

        event = {"SFN_EXECUTION_ID": "exec-005"}
        result = handler(event, _fake_lambda_context())

        assert result["total_chunks"] == 1
        assert result["chunks"][0]["object_count"] == 1
        assert result["chunks"][0]["object_keys"] == ["only.jsonl"]

    @patch("main.s3")
    def test_exact_chunk_size_no_remainder(self, mock_s3):
        report = {
            "objects": [
                {"key": f"obj-{i}.jsonl", "valid": True}
                for i in range(DEFAULT_CHUNK_SIZE * 3)
            ]
        }
        mock_s3.get_object.return_value = {
            "Body": MagicMock(read=lambda: json.dumps(report).encode())
        }

        event = {"SFN_EXECUTION_ID": "exec-006"}
        result = handler(event, _fake_lambda_context())

        assert result["total_chunks"] == 3
        assert all(
            c["object_count"] == DEFAULT_CHUNK_SIZE for c in result["chunks"]
        )

    @patch("main.s3")
    def test_writes_split_plan_to_s3(self, mock_s3):
        report = {"objects": [{"key": "a.jsonl", "valid": True}]}
        mock_s3.get_object.return_value = {
            "Body": MagicMock(read=lambda: json.dumps(report).encode())
        }

        event = {"SFN_EXECUTION_ID": "exec-007"}
        handler(event, _fake_lambda_context())

        mock_s3.put_object.assert_called_once()
        call_kwargs = mock_s3.put_object.call_args[1]
        assert call_kwargs["Bucket"] == "test-intermediate"
        assert "exec-007/split_workload/split_plan.json" == call_kwargs["Key"]

        plan = json.loads(call_kwargs["Body"])
        assert plan["total_chunks"] == 1
        assert plan["chunk_size"] == DEFAULT_CHUNK_SIZE

    @patch("main.s3")
    def test_fallback_when_report_not_found(self, mock_s3):
        mock_s3.get_object.side_effect = Exception("not found")

        event = {"SFN_EXECUTION_ID": "exec-008"}
        result = handler(event, _fake_lambda_context())

        assert result["chunks"] == []
        assert result["total_chunks"] == 0

    @patch("main.s3")
    def test_info_logs_do_not_contain_raw_step_or_execution_input(
        self, mock_s3, caplog
    ):
        # STEP_* values and EXECUTION_INPUT contents must NEVER be emitted at
        # INFO — copying this template into production would otherwise spill
        # upstream, potentially caller-supplied, data into CloudWatch Logs.
        report = {"objects": [{"key": "a.jsonl", "valid": True}]}
        mock_s3.get_object.return_value = {
            "Body": MagicMock(read=lambda: json.dumps(report).encode())
        }

        sensitive_step_value = "SENSITIVE-STEP-VALUE-8f2a"
        sensitive_input_value = "SENSITIVE-EXEC-INPUT-VALUE-1c3e"
        event = {
            "SFN_EXECUTION_ID": "exec-009",
            "STEP_INGEST_RAW_DATA": {"token": sensitive_step_value},
            "EXECUTION_INPUT": {"secret": sensitive_input_value},
        }

        with caplog.at_level("INFO"):
            handler(event, _fake_lambda_context())

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
