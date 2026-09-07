# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: MIT-0

"""Tests for the simple_step batch entrypoint."""

import json
from unittest.mock import MagicMock, patch

import pytest

from main import main


# Realistic execution input shape produced by Step Functions for this pipeline.
SAMPLE_EXECUTION_INPUT = {
    "inputs": {
        "type": "s3_discovery",
        "root_prefix": "input/simulation-data",
    }
}

# main() writes one result.json per subdirectory in this list.
EXPECTED_RESULT_SUBDIRS = ["result1", "result2"]


class TestMain:
    """Tests for main() with mocked S3."""

    @pytest.fixture(autouse=True)
    def _env(self, monkeypatch):
        monkeypatch.setenv("INTERMEDIATE_BUCKET", "test-intermediate")
        monkeypatch.setenv("SOURCE_BUCKET", "test-source")
        monkeypatch.setenv(
            "EXECUTION_INPUT", json.dumps(SAMPLE_EXECUTION_INPUT)
        )

    def _build_mock_s3(self, contents):
        """Return a mock S3 client whose list/get/put behave consistently.

        - list_objects_v2 returns the supplied Contents.
        - get_object handles both the loop reads (per source key in the
          source bucket) and the per-iteration write-verification read of
          the just-written intermediate object.
        - put_object captures the body so the verification read returns it.
        """
        mock_s3 = MagicMock()
        state = {"last_body": b""}

        mock_s3.list_objects_v2.return_value = {"Contents": list(contents)}

        def _get_object(Bucket, Key, **_):
            if Bucket == "test-intermediate":
                return {"Body": MagicMock(read=lambda: state["last_body"])}
            return {"Body": MagicMock(read=lambda: b"source-bytes")}

        def _put_object(Bucket, Key, Body, ContentType, **_):
            state["last_body"] = (
                Body.encode() if isinstance(Body, str) else Body
            )
            return {}

        mock_s3.get_object.side_effect = _get_object
        mock_s3.put_object.side_effect = _put_object
        return mock_s3, state

    @patch("main.boto3")
    def test_writes_result_to_each_subdir_using_root_prefix(self, mock_boto3):
        mock_s3, _ = self._build_mock_s3(
            [
                {"Key": "input/simulation-data/run-01.json", "Size": 10},
                {"Key": "input/simulation-data/run-02.json", "Size": 20},
            ]
        )
        mock_boto3.client.return_value = mock_s3

        main()

        # Listed once under the prefix from EXECUTION_INPUT.inputs.root_prefix.
        mock_s3.list_objects_v2.assert_called_once_with(
            Bucket="test-source", Prefix="input/simulation-data"
        )

        # One put_object per subdir, each with the same payload.
        assert mock_s3.put_object.call_count == len(EXPECTED_RESULT_SUBDIRS)
        keys = [c.kwargs["Key"] for c in mock_s3.put_object.call_args_list]
        assert keys == [
            f"exec-001/simple_step/{subdir}/result.json"
            for subdir in EXPECTED_RESULT_SUBDIRS
        ]
        for call in mock_s3.put_object.call_args_list:
            assert call.kwargs["Bucket"] == "test-intermediate"
            assert call.kwargs["ContentType"] == "application/json"
            body = json.loads(call.kwargs["Body"])
            assert body == {
                "source_path": "input/simulation-data",
                "files_read": 2,
                "objects": [
                    {"key": "input/simulation-data/run-01.json", "size": 10},
                    {"key": "input/simulation-data/run-02.json", "size": 20},
                ],
            }

    @patch("main.boto3")
    def test_falls_back_to_bucket_root_when_root_prefix_missing(
        self, mock_boto3, monkeypatch
    ):
        # inputs present but no root_prefix → fall back to "".
        monkeypatch.setenv(
            "EXECUTION_INPUT",
            json.dumps({"inputs": {"type": "s3_discovery"}}),
        )
        mock_s3, _ = self._build_mock_s3(
            [{"Key": "top-level.json", "Size": 5}]
        )
        mock_boto3.client.return_value = mock_s3

        main()

        mock_s3.list_objects_v2.assert_called_once_with(
            Bucket="test-source", Prefix=""
        )
        assert mock_s3.put_object.call_count == len(EXPECTED_RESULT_SUBDIRS)
        body = json.loads(mock_s3.put_object.call_args_list[0].kwargs["Body"])
        assert body["source_path"] == ""
        assert body["files_read"] == 1

    @patch("main.boto3")
    def test_falls_back_when_inputs_key_absent(self, mock_boto3, monkeypatch):
        # EXECUTION_INPUT shape lacks the "inputs" key entirely.
        monkeypatch.setenv("EXECUTION_INPUT", json.dumps({"other": "value"}))
        mock_s3, _ = self._build_mock_s3([{"Key": "anything.json", "Size": 1}])
        mock_boto3.client.return_value = mock_s3

        main()

        mock_s3.list_objects_v2.assert_called_once_with(
            Bucket="test-source", Prefix=""
        )

    @patch("main.boto3")
    def test_logs_previous_step_results_from_env(
        self, mock_boto3, monkeypatch
    ):
        # STEP_* env vars (other than STEP_NAME) are iterated and logged;
        # they must not affect the S3 interaction.
        monkeypatch.setenv("STEP_INGEST", json.dumps({"records": 5}))
        monkeypatch.setenv("STEP_VALIDATE", "ok")
        mock_s3, _ = self._build_mock_s3(
            [{"Key": "input/simulation-data/run-01.json", "Size": 10}]
        )
        mock_boto3.client.return_value = mock_s3

        main()

        assert mock_s3.put_object.call_count == len(EXPECTED_RESULT_SUBDIRS)

    @patch("main.boto3")
    def test_info_logs_do_not_contain_raw_step_or_execution_input(
        self, mock_boto3, monkeypatch, caplog
    ):
        # STEP_* values and EXECUTION_INPUT contents must NEVER be emitted at
        # INFO — customers copying this template into production would otherwise
        # spill caller-supplied data into CloudWatch Logs.
        sensitive_step_value = "SENSITIVE-STEP-VALUE-8f2a"
        sensitive_input_value = "SENSITIVE-EXEC-INPUT-VALUE-1c3e"
        monkeypatch.setenv("STEP_INGEST", sensitive_step_value)
        monkeypatch.setenv(
            "EXECUTION_INPUT",
            json.dumps(
                {
                    "inputs": {
                        "root_prefix": "input/simulation-data",
                        "secret": sensitive_input_value,
                    }
                }
            ),
        )
        mock_s3, _ = self._build_mock_s3(
            [{"Key": "input/simulation-data/run-01.json", "Size": 10}]
        )
        mock_boto3.client.return_value = mock_s3

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

    @patch("main.boto3")
    def test_raises_when_source_bucket_is_empty(self, mock_boto3):
        mock_s3, _ = self._build_mock_s3([])
        mock_boto3.client.return_value = mock_s3

        with pytest.raises(RuntimeError, match="No objects found"):
            main()

        mock_s3.put_object.assert_not_called()

    @patch("main.boto3")
    def test_raises_on_first_iteration_when_verification_mismatches(
        self, mock_boto3
    ):
        # Verification mismatch on the first subdir aborts before the second
        # put_object is issued.
        mock_s3 = MagicMock()
        mock_s3.list_objects_v2.return_value = {
            "Contents": [
                {"Key": "input/simulation-data/run-01.json", "Size": 10}
            ]
        }

        def _get_object(Bucket, Key, **_):
            if Bucket == "test-intermediate":
                return {"Body": MagicMock(read=lambda: b'{"tampered": true}')}
            return {"Body": MagicMock(read=lambda: b"source-bytes")}

        mock_s3.get_object.side_effect = _get_object
        mock_boto3.client.return_value = mock_s3

        with pytest.raises(AssertionError, match="Write verification failed"):
            main()

        # Only the first subdir's put_object happened before the assert tripped.
        assert mock_s3.put_object.call_count == 1

    @patch("main.boto3")
    def test_missing_intermediate_bucket_raises_keyerror(
        self, mock_boto3, monkeypatch
    ):
        monkeypatch.delenv("INTERMEDIATE_BUCKET", raising=False)

        with pytest.raises(KeyError, match="INTERMEDIATE_BUCKET"):
            main()

        mock_boto3.client.assert_not_called()

    @patch("main.boto3")
    def test_missing_source_bucket_raises_keyerror(
        self, mock_boto3, monkeypatch
    ):
        monkeypatch.delenv("SOURCE_BUCKET", raising=False)

        with pytest.raises(KeyError, match="SOURCE_BUCKET"):
            main()

        mock_boto3.client.assert_not_called()

    @patch("main.boto3")
    def test_missing_execution_input_falls_back_to_bucket_root(
        self, mock_boto3, monkeypatch
    ):
        # When EXECUTION_INPUT is unset, main() treats it as an empty dict
        # (default "{}"), the inputs/root_prefix lookup misses, and the
        # function falls back to listing the bucket root.
        monkeypatch.delenv("EXECUTION_INPUT", raising=False)
        mock_s3, _ = self._build_mock_s3(
            [{"Key": "top-level.json", "Size": 5}]
        )
        mock_boto3.client.return_value = mock_s3

        main()

        mock_s3.list_objects_v2.assert_called_once_with(
            Bucket="test-source", Prefix=""
        )
        assert mock_s3.put_object.call_count == len(EXPECTED_RESULT_SUBDIRS)
        body = json.loads(mock_s3.put_object.call_args_list[0].kwargs["Body"])
        assert body["source_path"] == ""
        assert body["files_read"] == 1
