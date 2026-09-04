# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: MIT-0

import boto3
import pytest


def pytest_addoption(parser):
    parser.addoption("--sfn-arn", action="store", help="Step Function ARN")


@pytest.fixture
def sfn_arn(request):
    arn = request.config.getoption("--sfn-arn")
    if not arn:
        pytest.fail("--sfn-arn is required")
    return arn


@pytest.fixture
def aws_region(sfn_arn):
    return sfn_arn.split(":")[3]


@pytest.fixture
def sfn_client(aws_region):
    return boto3.client("stepfunctions", region_name=aws_region)


@pytest.fixture
def s3_client(aws_region):
    return boto3.client("s3", region_name=aws_region)
