#!/bin/bash

# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: MIT-0

set -e
cd lambdas
poetry install
poetry run pytest
echo "Tests completed successfully!"
