# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: MIT-0

"""Tests for publish_report step."""

import contextlib
import json
from unittest.mock import MagicMock, patch

import pytest

from main import handler


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
        monkeypatch.setenv("STEP_NAME", "publish_report")
        monkeypatch.setenv("INTERMEDIATE_BUCKET", "test-intermediate")
        monkeypatch.setenv("REPORT_FORMAT", "json")
        monkeypatch.setenv(
            "DISTRIBUTION_LIST", "alice@example.com,bob@example.com"
        )

    @patch("main.s3")
    def test_publishes_report_from_aggregated_data(self, mock_s3):
        aggregated = {
            "total_records_scored": 100,
            "overall_avg_score": 0.75,
            "high_quality_records": 60,
            "low_quality_records": 40,
            "total_chunks_processed": 5,
            "chunk_summaries": [
                {"chunk_id": 0, "scored": 20, "avg_score": 0.8},
            ],
        }
        mock_s3.get_object.return_value = {
            "Body": MagicMock(read=lambda: json.dumps(aggregated).encode())
        }

        event = {
            "SFN_EXECUTION_ID": "exec-001",
            "STEP_INGEST_RAW_DATA": "data",
            "STEP_VALIDATE_INGESTION": "data",
            "STEP_SPLIT_WORKLOAD": "data",
            "STEP_AGGREGATE_RESULTS": "data",
        }

        result = handler(event, _fake_lambda_context())

        assert result["status"] == "success"
        assert result["total_records"] == 100
        assert result["avg_score"] == 0.75

        # Verify the written report structure
        call_kwargs = mock_s3.put_object.call_args[1]
        report = json.loads(call_kwargs["Body"])
        assert report["format"] == "json"
        assert report["distribution"] == [
            "alice@example.com",
            "bob@example.com",
        ]
        assert report["summary"]["total_records"] == 100
        assert report["summary"]["chunks_processed"] == 5
        assert len(report["details"]) == 1

    @patch("main.s3")
    def test_fallback_when_aggregated_report_missing(self, mock_s3):
        mock_s3.get_object.side_effect = Exception("not found")

        event = {"SFN_EXECUTION_ID": "exec-002"}
        result = handler(event, _fake_lambda_context())

        assert result["status"] == "success"
        assert result["total_records"] == 0

    @patch("main.s3")
    def test_empty_distribution_list(self, mock_s3, monkeypatch):
        monkeypatch.setenv("DISTRIBUTION_LIST", "")
        aggregated = {
            "total_records_scored": 10,
            "overall_avg_score": 0.5,
            "high_quality_records": 5,
            "low_quality_records": 5,
            "total_chunks_processed": 1,
            "chunk_summaries": [],
        }
        mock_s3.get_object.return_value = {
            "Body": MagicMock(read=lambda: json.dumps(aggregated).encode())
        }

        event = {"SFN_EXECUTION_ID": "exec-003"}
        handler(event, _fake_lambda_context())

        call_kwargs = mock_s3.put_object.call_args[1]
        report = json.loads(call_kwargs["Body"])
        assert report["distribution"] == []

    @patch("main.s3")
    def test_report_output_path(self, mock_s3):
        aggregated = {"total_records_scored": 0, "overall_avg_score": 0}
        mock_s3.get_object.return_value = {
            "Body": MagicMock(read=lambda: json.dumps(aggregated).encode())
        }

        event = {"SFN_EXECUTION_ID": "exec-004"}
        result = handler(event, _fake_lambda_context())

        assert (
            "exec-004/publish_report/published_report.json"
            in result["report_path"]
        )

    @patch("main.s3")
    def test_info_logs_do_not_contain_raw_step_or_execution_input(
        self, mock_s3, caplog
    ):
        # STEP_* values and EXECUTION_INPUT contents must NEVER be emitted at
        # INFO — copying this template into production would otherwise spill
        # upstream, potentially caller-supplied, data into CloudWatch Logs.
        sensitive_step_value = "SENSITIVE-STEP-VALUE-8f2a"
        sensitive_input_value = "SENSITIVE-EXEC-INPUT-VALUE-1c3e"
        event = {
            "SFN_EXECUTION_ID": "exec-sec",
            "MAP_ITEM": {"chunk_id": 0},
            "STEP_INGEST_RAW_DATA": {"token": sensitive_step_value},
            "EXECUTION_INPUT": {"secret": sensitive_input_value},
        }

        with caplog.at_level("INFO"), contextlib.suppress(Exception):
            # The logging block runs before any S3 work; tolerate downstream
            # errors from incomplete mocks and assert only on emitted logs.
            handler(event, _fake_lambda_context())

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
