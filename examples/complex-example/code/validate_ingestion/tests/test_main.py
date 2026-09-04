# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: MIT-0

"""Tests for validate_ingestion step."""

import contextlib
import json
from unittest.mock import MagicMock, patch

import pytest

from main import _validate_object, handler


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


class TestValidateObject:
    """Tests for the _validate_object helper."""

    def test_valid_object_standard_profile(self):
        obj = {"key": "data/file.jsonl", "size": 1024}
        assert _validate_object(obj, "standard") == []

    def test_empty_file_detected(self):
        obj = {"key": "data/empty.jsonl", "size": 0}
        issues = _validate_object(obj, "standard")
        assert len(issues) == 1
        assert issues[0]["type"] == "empty_file"

    def test_strict_profile_rejects_non_jsonl(self):
        obj = {"key": "data/file.csv", "size": 100}
        issues = _validate_object(obj, "strict")
        assert len(issues) == 1
        assert issues[0]["type"] == "unexpected_format"

    def test_strict_profile_accepts_jsonl(self):
        obj = {"key": "data/file.jsonl", "size": 100}
        assert _validate_object(obj, "strict") == []

    def test_strict_profile_empty_and_wrong_format(self):
        obj = {"key": "data/file.csv", "size": 0}
        issues = _validate_object(obj, "strict")
        assert len(issues) == 2
        types = {i["type"] for i in issues}
        assert types == {"empty_file", "unexpected_format"}

    def test_missing_size_treated_as_zero(self):
        obj = {"key": "data/file.jsonl"}
        issues = _validate_object(obj, "standard")
        assert len(issues) == 1
        assert issues[0]["type"] == "empty_file"


class TestHandler:
    """Tests for the Lambda handler with mocked S3."""

    @pytest.fixture(autouse=True)
    def _env(self, monkeypatch):
        monkeypatch.setenv("STEP_NAME", "validate_ingestion")
        monkeypatch.setenv("INTERMEDIATE_BUCKET", "test-intermediate")
        monkeypatch.setenv("VALIDATION_PROFILE", "standard")

    @patch("main.s3")
    def test_handler_with_manifest(self, mock_s3):
        manifest = {
            "objects": [
                {"key": "a.jsonl", "size": 100},
                {"key": "b.jsonl", "size": 0},
            ]
        }
        mock_s3.get_object.return_value = {
            "Body": MagicMock(read=lambda: json.dumps(manifest).encode())
        }
        mock_s3.exceptions = type(
            "Exc", (), {"NoSuchKey": type("NoSuchKey", (Exception,), {})}
        )()

        event = {
            "SFN_EXECUTION_ID": "exec-001",
            "STEP_INGEST_RAW_DATA": {"some": "data"},
        }

        result = handler(event, _fake_lambda_context())

        assert result["status"] == "success"
        assert result["valid_objects"] == 1
        assert result["invalid_objects"] == 1
        mock_s3.put_object.assert_called_once()

    @patch("main.s3")
    def test_handler_manifest_not_found_uses_payload(self, mock_s3):
        no_such_key = type("NoSuchKey", (Exception,), {})
        mock_s3.exceptions = type("Exc", (), {"NoSuchKey": no_such_key})()
        mock_s3.get_object.side_effect = no_such_key("not found")

        event = {
            "SFN_EXECUTION_ID": "exec-002",
            "ingest_raw_data_result": {
                "Payload": {"objects": [{"key": "c.jsonl", "size": 50}]}
            },
        }

        result = handler(event, _fake_lambda_context())

        assert result["status"] == "success"
        assert result["valid_objects"] == 1
        assert result["invalid_objects"] == 0

    @patch("main.s3")
    def test_handler_strict_profile(self, mock_s3, monkeypatch):
        monkeypatch.setenv("VALIDATION_PROFILE", "strict")
        manifest = {
            "objects": [
                {"key": "good.jsonl", "size": 100},
                {"key": "bad.csv", "size": 200},
            ]
        }
        mock_s3.get_object.return_value = {
            "Body": MagicMock(read=lambda: json.dumps(manifest).encode())
        }
        mock_s3.exceptions = type(
            "Exc", (), {"NoSuchKey": type("NoSuchKey", (Exception,), {})}
        )()

        event = {"SFN_EXECUTION_ID": "exec-003"}
        result = handler(event, _fake_lambda_context())

        assert result["valid_objects"] == 1
        assert result["invalid_objects"] == 1

    @patch("main.s3")
    def test_handler_empty_manifest(self, mock_s3):
        manifest = {"objects": []}
        mock_s3.get_object.return_value = {
            "Body": MagicMock(read=lambda: json.dumps(manifest).encode())
        }
        mock_s3.exceptions = type(
            "Exc", (), {"NoSuchKey": type("NoSuchKey", (Exception,), {})}
        )()

        event = {"SFN_EXECUTION_ID": "exec-004"}
        result = handler(event, _fake_lambda_context())

        assert result["valid_objects"] == 0
        assert result["invalid_objects"] == 0

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
