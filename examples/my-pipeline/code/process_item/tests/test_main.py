# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: MIT-0

"""Tests for the process_item Lambda step."""

import json
from unittest.mock import patch

import pytest

from main import handler


class TestHandler:
    """Tests for the Lambda handler with mocked S3."""

    @pytest.fixture(autouse=True)
    def _env(self, monkeypatch):
        monkeypatch.setenv("STEP_NAME", "process_item")
        monkeypatch.setenv("INTERMEDIATE_BUCKET", "test-intermediate")

    @patch("main.s3")
    def test_writes_marker_to_intermediate_bucket(self, mock_s3):
        event = {
            "SFN_EXECUTION_ID": "exec-001",
            "MAP_ITEM": "exec-001/discover_sources/batch-a/",
        }

        result = handler(event, None)

        assert result == {
            "status": "success",
            "source": "exec-001/discover_sources/batch-a/",
        }
        mock_s3.put_object.assert_called_once()
        call_kwargs = mock_s3.put_object.call_args[1]
        assert call_kwargs["Bucket"] == "test-intermediate"
        assert call_kwargs["ContentType"] == "application/json"
        body = json.loads(call_kwargs["Body"])
        assert body == {
            "source": "exec-001/discover_sources/batch-a/",
            "status": "processed",
        }

    @patch("main.s3")
    def test_output_key_strips_exec_id_and_source_step(self, mock_s3):
        # map_item already has "<exec_id>/<source_step>/<rest>".
        # Output key should be "<exec_id>/<step_name>/<rest>processed.json".
        event = {
            "SFN_EXECUTION_ID": "exec-001",
            "MAP_ITEM": "exec-001/discover_sources/batch-a/",
        }

        handler(event, None)

        key = mock_s3.put_object.call_args[1]["Key"]
        assert key == "exec-001/process_item/batch-a/processed.json"

    @patch("main.s3")
    def test_output_key_for_nested_subprefix(self, mock_s3):
        # Nested suffix beyond the first two segments is preserved verbatim.
        event = {
            "SFN_EXECUTION_ID": "exec-002",
            "MAP_ITEM": "exec-002/discover_sources/batch-a/sub-b/",
        }

        handler(event, None)

        key = mock_s3.put_object.call_args[1]["Key"]
        assert key == "exec-002/process_item/batch-a/sub-b/processed.json"

    @patch("main.s3")
    def test_handler_ignores_optional_execution_input(self, mock_s3):
        # EXECUTION_INPUT is logged when present but must not affect S3 output.
        event = {
            "SFN_EXECUTION_ID": "exec-001",
            "MAP_ITEM": "exec-001/discover_sources/batch-a/",
            "EXECUTION_INPUT": {"reason": "manual run"},
        }

        result = handler(event, None)

        assert result["status"] == "success"
        mock_s3.put_object.assert_called_once()

    @patch("main.s3")
    def test_handler_logs_previous_step_results(self, mock_s3):
        # Keys starting with "STEP_" are logged but should not affect S3 output.
        event = {
            "SFN_EXECUTION_ID": "exec-001",
            "MAP_ITEM": "exec-001/discover_sources/batch-a/",
            "STEP_DISCOVER_SOURCES": {"items_found": 5},
            "STEP_FILTER": {"items_kept": 3},
        }

        handler(event, None)

        # Only one S3 write regardless of the number of STEP_ keys.
        mock_s3.put_object.assert_called_once()

    @patch("main.s3")
    def test_missing_intermediate_bucket_raises(self, mock_s3, monkeypatch):
        monkeypatch.delenv("INTERMEDIATE_BUCKET", raising=False)
        event = {
            "SFN_EXECUTION_ID": "exec-001",
            "MAP_ITEM": "exec-001/discover_sources/batch-a/",
        }

        with pytest.raises(KeyError, match="INTERMEDIATE_BUCKET"):
            handler(event, None)

        mock_s3.put_object.assert_not_called()

    @patch("main.s3")
    def test_missing_map_item_raises(self, mock_s3):
        event = {"SFN_EXECUTION_ID": "exec-001"}

        with pytest.raises(KeyError, match="MAP_ITEM"):
            handler(event, None)

        mock_s3.put_object.assert_not_called()

    @patch("main.s3")
    def test_missing_sfn_execution_id_raises(self, mock_s3):
        event = {"MAP_ITEM": "exec-001/discover_sources/batch-a/"}

        with pytest.raises(KeyError, match="SFN_EXECUTION_ID"):
            handler(event, None)

        mock_s3.put_object.assert_not_called()

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
            "SFN_EXECUTION_ID": "exec-001",
            "MAP_ITEM": "exec-001/discover_sources/batch-a/",
            "STEP_DISCOVER_SOURCES": {"token": sensitive_step_value},
            "EXECUTION_INPUT": {"secret": sensitive_input_value},
        }

        with caplog.at_level("INFO"):
            handler(event, None)

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
