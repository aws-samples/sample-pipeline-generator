# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: MIT-0

# CloudWatch Log Group for Batch jobs
resource "aws_cloudwatch_log_group" "batch" {
  name              = "/aws/batch/${local.pipeline_name}-${local.environment}"
  retention_in_days = var.cw_retention_days
  kms_key_id        = local.cloudwatch_kms_key

  tags = local.common_tags
}

locals {
  # All log groups owned by this pipeline. Update when adding new log sources.
  pipeline_log_group_names = concat(
    [aws_cloudwatch_log_group.batch.name],
    [aws_cloudwatch_log_group.step_functions.name],
    [for lg in aws_cloudwatch_log_group.lambda_steps : lg.name],
    [for lg in aws_cloudwatch_log_group.pipeline_lambda : lg.name],
  )

  query_namespace = "Pipelines/${local.pipeline_name}/${local.environment}"
}

# Field indexes — make `filter run_id = "..."` near-instant.
resource "aws_cloudwatch_log_index_policy" "pipeline" {
  for_each       = toset(local.pipeline_log_group_names)
  log_group_name = each.value

  policy_document = jsonencode({
    Fields = ["run_id", "level"]
  })
}

# Saved Logs Insights queries scoped to this pipeline's log groups.
resource "aws_cloudwatch_query_definition" "all_logs_of_run" {
  name            = "${local.query_namespace}/All logs of a run"
  log_group_names = local.pipeline_log_group_names

  query_string = <<-EOT
    fields @timestamp, step_name, level, message, @log, @logStream
    | filter run_id = "REPLACE_WITH_RUN_ID"
    | sort @timestamp asc
    | limit 10000
  EOT
}

resource "aws_cloudwatch_query_definition" "errors_by_run" {
  name            = "${local.query_namespace}/Errors per run"
  log_group_names = local.pipeline_log_group_names

  query_string = <<-EOT
    fields @timestamp, run_id, step_name, level, message
    | filter level = "ERROR"
    | stats count(*) as errors by run_id, step_name
    | sort errors desc
  EOT
}

resource "aws_cloudwatch_query_definition" "tail_run" {
  name            = "${local.query_namespace}/Tail latest events of a run"
  log_group_names = local.pipeline_log_group_names

  query_string = <<-EOT
    fields @timestamp, step_name, level, message
    | filter run_id = "REPLACE_WITH_RUN_ID"
    | sort @timestamp desc
    | limit 200
  EOT
}

# SFN-only — derives per-step wall-clock time from Step Functions events.
resource "aws_cloudwatch_query_definition" "step_durations" {
  name            = "${local.query_namespace}/Step durations of a run"
  log_group_names = [aws_cloudwatch_log_group.step_functions.name]

  query_string = <<-EOT
    fields @timestamp, type, details.name as step_name, execution_arn
    | filter type in ["TaskStateEntered", "TaskStateExited"]
    | filter execution_arn like "REPLACE_WITH_RUN_ID"
    | stats
        earliest(@timestamp) as started,
        latest(@timestamp)   as ended,
        (latest(@timestamp) - earliest(@timestamp)) / 1000 as duration_s
      by step_name
    | sort started asc
  EOT
}

# ─────────────────────────────────────────────────────────────────────────────
# Pipeline-wide saved queries — no run_id placeholder. These answer questions
# about the pipeline as a whole ("what's going on right now?", "which step is
# flaky?", "which run was slowest?") without needing the caller to paste a
# specific run_id first. All four are scoped to this pipeline's log groups via
# `log_group_names`, which the CloudWatch console pre-selects when the saved
# query is opened.
# ─────────────────────────────────────────────────────────────────────────────

# Every ERROR in the pipeline in the query window, with run_id + step_name
# so you can jump from a noisy event to the run that produced it.
resource "aws_cloudwatch_query_definition" "recent_errors" {
  name            = "${local.query_namespace}/Recent errors (pipeline)"
  log_group_names = local.pipeline_log_group_names

  query_string = <<-EOT
    fields @timestamp, run_id, step_name, level, message, @log, @logStream
    | filter level = "ERROR"
    | sort @timestamp desc
    | limit 500
  EOT
}

# Every Log in the pipeline in the query window, with run_id + step_name
# so you can jump from a noisy event to the run that produced it.
resource "aws_cloudwatch_query_definition" "recent_runs" {
  name            = "${local.query_namespace}/Recent runs (pipeline)"
  log_group_names = local.pipeline_log_group_names

  query_string = <<-EOT
    fields @timestamp, run_id, step_name, level, message, @log, @logStream
    | sort @timestamp desc
    | limit 500
  EOT
}

# Distinct run_ids with event counts and earliest/latest timestamps — the
# "what ran recently?" view. Sorted by latest desc so the newest run is at
# the top.
resource "aws_cloudwatch_query_definition" "runs_overview" {
  name            = "${local.query_namespace}/Runs overview"
  log_group_names = local.pipeline_log_group_names

  query_string = <<-EOT
    fields @timestamp, run_id
    | filter ispresent(run_id)
    | stats
        count(*)             as events,
        earliest(@timestamp) as started,
        latest(@timestamp)   as last_seen
      by run_id
    | sort last_seen desc
    | limit 200
  EOT
}

# Aggregate error volume per step across every run in the window. Surfaces
# the flakiest steps of the pipeline over time.
resource "aws_cloudwatch_query_definition" "error_rate_by_step" {
  name            = "${local.query_namespace}/Error rate by step"
  log_group_names = local.pipeline_log_group_names

  query_string = <<-EOT
    fields @timestamp, step_name, level
    | filter ispresent(step_name)
    | stats
        sum(strcontains(level, "ERROR")) as errors,
        count(*)                         as events,
        (sum(strcontains(level, "ERROR")) * 100.0 / count(*)) as error_rate_pct
      by step_name
    | sort errors desc
  EOT
}

# SFN-only — wall-clock duration per execution across all runs in the
# window. Sorted longest first to spot slow runs.
resource "aws_cloudwatch_query_definition" "run_durations" {
  name            = "${local.query_namespace}/Run durations (pipeline)"
  log_group_names = [aws_cloudwatch_log_group.step_functions.name]

  query_string = <<-EOT
    fields @timestamp, type, execution_arn
    | filter type in ["ExecutionStarted", "ExecutionSucceeded", "ExecutionFailed", "ExecutionAborted", "ExecutionTimedOut"]
    | stats
        earliest(@timestamp) as started,
        latest(@timestamp)   as ended,
        (latest(@timestamp) - earliest(@timestamp)) / 1000 as duration_s
      by execution_arn
    | sort duration_s desc
    | limit 100
  EOT
}
