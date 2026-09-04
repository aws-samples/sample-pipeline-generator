# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: MIT-0

FROM public.ecr.aws/docker/library/python:3.13-slim

WORKDIR /app

COPY pyproject.toml poetry.lock ./
RUN pip install --no-cache-dir "poetry==1.8.3" && \
    poetry config virtualenvs.create false && \
    poetry install --only=main --no-root --sync && \
    pip uninstall -y poetry && \
    rm -rf /root/.cache

COPY copy_data.py .

RUN useradd --no-create-home --shell /usr/sbin/nologin appuser
USER appuser

ENTRYPOINT ["python3", "copy_data.py"]
