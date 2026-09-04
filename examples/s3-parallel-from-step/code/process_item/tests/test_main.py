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
            "MAP_ITEM": "exec-001/prepare_data/batch-a/",
        }

        result = handler(event, None)

        assert result["status"] == "success"
        mock_s3.put_object.assert_called_once()
        call_kwargs = mock_s3.put_object.call_args[1]
        assert call_kwargs["Bucket"] == "test-intermediate"
        assert call_kwargs["ContentType"] == "application/json"
        body = json.loads(call_kwargs["Body"])
        assert body["status"] == "processed"

    @patch("main.s3")
    def test_missing_map_item_raises(self, mock_s3):
        with pytest.raises(KeyError, match="MAP_ITEM"):
            handler({"SFN_EXECUTION_ID": "exec-001"}, None)
        mock_s3.put_object.assert_not_called()

    @patch("main.s3")
    def test_missing_sfn_execution_id_raises(self, mock_s3):
        with pytest.raises(KeyError, match="SFN_EXECUTION_ID"):
            handler({"MAP_ITEM": "exec-001/prepare_data/batch-a/"}, None)
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
            "MAP_ITEM": "exec-001/prepare_data/batch-a/",
            "STEP_DISCOVER_SOURCES": {"token": sensitive_step_value},
            "EXECUTION_INPUT": {"secret": sensitive_input_value},
        }

        with caplog.at_level("INFO"):
            handler(event, None)

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
