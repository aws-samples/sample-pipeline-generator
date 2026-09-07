# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: MIT-0

FROM public.ecr.aws/docker/library/python:3.13-slim

WORKDIR /app

COPY pyproject.toml .
RUN pip install --no-cache-dir poetry==1.8.3 && \
    poetry config virtualenvs.create false && \
    poetry install --only=main && \
    pip uninstall -y poetry && \
    rm -rf /root/.cache

COPY main.py .

RUN useradd --no-create-home --shell /usr/sbin/nologin appuser
USER appuser

CMD ["python", "main.py"]
