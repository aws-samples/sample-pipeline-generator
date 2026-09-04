# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: MIT-0

"""Tests for aggregate_results step."""

import contextlib
import json
from unittest.mock import MagicMock, patch

import pytest

from main import main


class TestMain:
    """Tests for the batch main() entrypoint with mocked S3."""

    @pytest.fixture(autouse=True)
    def _env(self, monkeypatch):
        monkeypatch.setenv("STEP_NAME", "aggregate_results")
        monkeypatch.setenv("INTERMEDIATE_BUCKET", "test-intermediate")
        monkeypatch.setenv("SFN_EXECUTION_ID", "exec-001")
        monkeypatch.setenv("STEP_INGEST_RAW_DATA", "{}")
        monkeypatch.setenv("STEP_VALIDATE_INGESTION", "{}")
        monkeypatch.setenv("STEP_SPLIT_WORKLOAD", "{}")

    @patch("main.boto3")
    def test_aggregates_chunk_scores(self, mock_boto3):
        mock_s3 = MagicMock()
        mock_boto3.client.return_value = mock_s3

        chunk_0 = {
            "chunk_id": 0,
            "total_scored": 3,
            "high_count": 2,
            "low_count": 1,
            "avg_score": 0.8,
            "records": [
                {"score": 0.9, "label": "high"},
                {"score": 0.8, "label": "high"},
                {"score": 0.5, "label": "low"},
            ],
        }
        chunk_1 = {
            "chunk_id": 1,
            "total_scored": 2,
            "high_count": 1,
            "low_count": 1,
            "avg_score": 0.6,
            "records": [
                {"score": 0.7, "label": "high"},
                {"score": 0.3, "label": "low"},
            ],
        }

        # Paginator returns score files
        mock_s3.get_paginator.return_value.paginate.return_value = [
            {
                "Contents": [
                    {"Key": "exec-001/score_chunk/chunk-0/scores.json"},
                    {"Key": "exec-001/score_chunk/chunk-1/scores.json"},
                ]
            }
        ]

        # get_object returns chunk data based on key
        def get_object_side_effect(Bucket, Key):
            data = chunk_0 if "chunk-0" in Key else chunk_1
            return {
                "Body": MagicMock(read=lambda d=data: json.dumps(d).encode())
            }

        mock_s3.get_object.side_effect = get_object_side_effect

        main()

        mock_s3.put_object.assert_called_once()
        call_kwargs = mock_s3.put_object.call_args[1]
        report = json.loads(call_kwargs["Body"])

        assert report["total_chunks_processed"] == 2
        assert report["total_records_scored"] == 5
        assert report["high_quality_records"] == 3
        assert report["low_quality_records"] == 2
        # (0.9 + 0.8 + 0.5 + 0.7 + 0.3) / 5 = 0.64
        assert report["overall_avg_score"] == pytest.approx(0.64, abs=0.001)

    @patch("main.boto3")
    def test_no_score_files(self, mock_boto3):
        mock_s3 = MagicMock()
        mock_boto3.client.return_value = mock_s3

        mock_s3.get_paginator.return_value.paginate.return_value = [
            {"Contents": []}
        ]

        main()

        call_kwargs = mock_s3.put_object.call_args[1]
        report = json.loads(call_kwargs["Body"])
        assert report["total_chunks_processed"] == 0
        assert report["total_records_scored"] == 0
        assert report["overall_avg_score"] == 0.0

    @patch("main.boto3")
    def test_skips_non_score_files(self, mock_boto3):
        mock_s3 = MagicMock()
        mock_boto3.client.return_value = mock_s3

        mock_s3.get_paginator.return_value.paginate.return_value = [
            {
                "Contents": [
                    {"Key": "exec-001/score_chunk/chunk-0/scores.json"},
                    {"Key": "exec-001/score_chunk/chunk-0/debug.log"},
                ]
            }
        ]

        chunk_data = {
            "chunk_id": 0,
            "total_scored": 1,
            "high_count": 1,
            "low_count": 0,
            "avg_score": 0.9,
            "records": [{"score": 0.9}],
        }
        mock_s3.get_object.return_value = {
            "Body": MagicMock(read=lambda: json.dumps(chunk_data).encode())
        }

        main()

        # get_object should only be called for scores.json, not debug.log
        assert mock_s3.get_object.call_count == 1

    @patch("main.boto3")
    def test_report_written_to_correct_path(self, mock_boto3):
        mock_s3 = MagicMock()
        mock_boto3.client.return_value = mock_s3
        mock_s3.get_paginator.return_value.paginate.return_value = [{}]

        main()

        call_kwargs = mock_s3.put_object.call_args[1]
        assert call_kwargs["Bucket"] == "test-intermediate"
        assert (
            call_kwargs["Key"]
            == "exec-001/aggregate_results/aggregated_report.json"
        )

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
