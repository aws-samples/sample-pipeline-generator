# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: MIT-0

"""Tests for score_chunk step."""

import contextlib
import json
from unittest.mock import MagicMock, patch

import pytest

from main import _compute_score, handler


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


class TestComputeScore:
    """Tests for the _compute_score helper."""

    def test_zero_records_returns_zero(self):
        assert _compute_score({"record_count": 0}) == 0.0

    def test_missing_record_count_returns_zero(self):
        assert _compute_score({}) == 0.0

    def test_score_scales_linearly(self):
        assert _compute_score({"record_count": 50}) == 0.5

    def test_score_capped_at_one(self):
        assert _compute_score({"record_count": 100}) == 1.0
        assert _compute_score({"record_count": 500}) == 1.0

    def test_small_record_count(self):
        score = _compute_score({"record_count": 1})
        assert score == pytest.approx(0.01)


class TestHandler:
    """Tests for the Lambda handler with mocked S3."""

    @pytest.fixture(autouse=True)
    def _env(self, monkeypatch):
        monkeypatch.setenv("STEP_NAME", "score_chunk")
        monkeypatch.setenv("INTERMEDIATE_BUCKET", "test-intermediate")

    @patch("main.s3")
    def test_scores_transformed_records(self, mock_s3):
        summary = {
            "records": [
                {
                    "source_key": "a.jsonl",
                    "record_count": 70,
                    "status": "transformed",
                },
                {
                    "source_key": "b.jsonl",
                    "record_count": 30,
                    "status": "transformed",
                },
            ]
        }
        mock_s3.get_object.return_value = {
            "Body": MagicMock(read=lambda: json.dumps(summary).encode())
        }

        event = {
            "SFN_EXECUTION_ID": "exec-001",
            "MAP_ITEM": {"chunk_id": 0},
        }

        result = handler(event, _fake_lambda_context())

        assert result["status"] == "success"
        assert result["total_scored"] == 2
        assert result["chunk_id"] == 0
        assert result["avg_score"] == pytest.approx(0.5)

    @patch("main.s3")
    def test_skips_error_records(self, mock_s3):
        summary = {
            "records": [
                {
                    "source_key": "a.jsonl",
                    "record_count": 50,
                    "status": "transformed",
                },
                {
                    "source_key": "b.jsonl",
                    "record_count": 0,
                    "status": "error",
                    "error": "fail",
                },
            ]
        }
        mock_s3.get_object.return_value = {
            "Body": MagicMock(read=lambda: json.dumps(summary).encode())
        }

        event = {
            "SFN_EXECUTION_ID": "exec-002",
            "MAP_ITEM": {"chunk_id": 1},
        }

        result = handler(event, _fake_lambda_context())

        assert result["total_scored"] == 1

    @patch("main.s3")
    def test_labels_high_and_low(self, mock_s3):
        summary = {
            "records": [
                {
                    "source_key": "high.jsonl",
                    "record_count": 80,
                    "status": "transformed",
                },
                {
                    "source_key": "low.jsonl",
                    "record_count": 10,
                    "status": "transformed",
                },
            ]
        }
        mock_s3.get_object.return_value = {
            "Body": MagicMock(read=lambda: json.dumps(summary).encode())
        }

        event = {
            "SFN_EXECUTION_ID": "exec-003",
            "MAP_ITEM": {"chunk_id": 0},
        }

        handler(event, _fake_lambda_context())

        # Verify labels via the written S3 object
        call_kwargs = mock_s3.put_object.call_args[1]
        written = json.loads(call_kwargs["Body"])
        labels = {r["source_key"]: r["label"] for r in written["records"]}
        assert labels["high.jsonl"] == "high"
        assert labels["low.jsonl"] == "low"

    @patch("main.s3")
    def test_map_item_as_json_string(self, mock_s3):
        summary = {"records": []}
        mock_s3.get_object.return_value = {
            "Body": MagicMock(read=lambda: json.dumps(summary).encode())
        }

        event = {
            "SFN_EXECUTION_ID": "exec-004",
            "MAP_ITEM": json.dumps({"chunk_id": 5}),
        }

        result = handler(event, _fake_lambda_context())

        assert result["chunk_id"] == 5

    @patch("main.s3")
    def test_fallback_when_summary_not_found(self, mock_s3):
        mock_s3.get_object.side_effect = Exception("not found")

        event = {
            "SFN_EXECUTION_ID": "exec-005",
            "MAP_ITEM": {"chunk_id": 0},
        }

        result = handler(event, _fake_lambda_context())

        assert result["status"] == "success"
        assert result["total_scored"] == 0
        assert result["avg_score"] == 0.0

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
