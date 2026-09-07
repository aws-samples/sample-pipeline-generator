# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: MIT-0

# ╔══════════════════════════════════════════════════════════════════════════════╗
# ║  Step Functions State Machine Definition                                    ║
# ║                                                                             ║
# ║  This file builds an AWS Step Functions state machine from a user-supplied  ║
# ║  list of pipeline steps (var.steps). The overall execution flow is:         ║
# ║                                                                             ║
# ║    Pre-parallel steps  (batch / lambda, run sequentially)                   ║
# ║        ↓                                                                    ║
# ║    Parallel-Block-Initialization  (auto-inserted before each parallel)      ║
# ║        ↓                                                                    ║
# ║    Parallel Map block  (fan-out over items produced by init step)           ║
# ║        ↓                                                                    ║
# ║    Post-parallel steps (batch / lambda, run sequentially)                   ║
# ║        ↓                                                                    ║
# ║    Copy-To-Output      (optional — copies intermediate data to output S3)   ║
# ║        ↓                                                                    ║
# ║    Pipeline-Completion-Notification  (SNS publish)                          ║
# ║        ↓                                                                    ║
# ║    End                                                                      ║
# ║                                                                             ║
# ║  The logic works in three phases:                                           ║
# ║    1. Build template parameters for each compute step (batch/lambda).       ║
# ║    2. Render each step from its JSON template, using "PLACEHOLDER" for the  ║
# ║       Next field.                                                           ║
# ║    3. Chain the rendered steps by replacing PLACEHOLDERs with the actual    ║
# ║       next state name, producing the final state machine JSON.              ║
# ╚══════════════════════════════════════════════════════════════════════════════╝

locals {
  # Unique name for the Step Functions state machine, scoped to the environment.
  sfn_pipeline_name = "${local.pipeline_name}-${local.environment}"

  # ────────────────────────────────────────────────────────────────────────────
  # Phase 1 — Build template parameters for every compute step
  # ────────────────────────────────────────────────────────────────────────────

  # Helper: auto-generate a ResultPath JSON fragment for every compute step.
  # Each step stores its output at $.<step_name>_result in the state machine's
  # execution context, so downstream steps can reference it.
  result_path_fragment = {
    for step in concat(
      [for s in var.steps : s if contains(["batch", "lambda"], s.type)],
      local.parallel_inner_steps
    ) : step.name => "\"ResultPath\": \"$.${step.name}_result\""
  }

  # Common template parameters for every compute step (batch or lambda).
  # This map is keyed by step name and consumed by templatefile() when rendering
  # the step's JSON template.
  #
  # Key fields:
  #   - job_definition / job_queue  — populated only for batch steps
  #   - function_arn                — populated only for lambda steps
  #   - runtime_parameters          — user-supplied params forwarded into the step
  #   - previous_steps              — a map of STEP_<NAME> → JSONPath references
  #                                   to every preceding step's result, allowing
  #                                   each step to consume outputs from earlier steps
  #   - result_path_json            — the ResultPath fragment for this step
  compute_step_params = {
    for step in concat(
      [for s in var.steps : s if contains(["batch", "lambda"], s.type)],
      local.parallel_inner_steps
      ) : step.name => {
      step_name          = step.name
      job_definition     = step.type == "batch" ? aws_batch_job_definition.batch_jobs[step.name].arn : ""
      job_queue          = step.type == "batch" ? aws_batch_job_queue.pipeline.arn : ""
      function_arn       = step.type == "lambda" ? aws_lambda_function.lambda_steps[step.name].arn : ""
      runtime_parameters = step.runtime_parameters

      # Build the previous_steps map so each step can reference outputs from
      # steps that ran before it. Two cases:
      #
      # 1. Steps INSIDE the parallel block — they can only see results from
      #    pre-parallel top-level steps (not sibling parallel iterations).
      #
      # 2. Top-level sequential steps — they see all preceding top-level steps.
      #
      # Lambda results are accessed via ".Payload" (Step Functions wraps Lambda
      # output); batch results are accessed directly.
      previous_steps = (
        # Steps inside the parallel block see all pre-parallel top-level steps
        contains(local.parallel_inner_steps[*].name, step.name)
        ? {
          for prev in local.pre_parallel :
          "STEP_${upper(replace(prev.name, "-", "_"))}" =>
          contains(["lambda"], prev.type) ? "${prev.name}_result.Payload" : "${prev.name}_result"
          if contains(["batch", "lambda"], prev.type)
        }
        : {
          for prev in local.all_top_level_ordered :
          "STEP_${upper(replace(prev.name, "-", "_"))}" =>
          contains(["lambda"], prev.type) ? "${prev.name}_result.Payload" : "${prev.name}_result"
          if prev.name != step.name && index(local.all_top_level_ordered[*].name, prev.name) < index(local.all_top_level_ordered[*].name, step.name)
        }
      )
      result_path_json = local.result_path_fragment[step.name]
    }
  }

  # ────────────────────────────────────────────────────────────────────────────
  # Phase 2 — Render each step from its JSON template
  # ────────────────────────────────────────────────────────────────────────────

  # 2a. Render the inner steps of the parallel (Map) block.
  # Each inner step gets MAP_ITEM as its item variable (the current element from
  # the fan-out array). Steps are chained within the iterator: each points to
  # the next, and the last step has no Next (is_last = true).
  rendered_parallel_inner_list = local.has_parallel ? [
    for i, step in local.parallel_inner_steps : templatefile(
      "${path.module}/step_functions/${step.type}_step.json.tpl",
      merge(local.compute_step_params[step.name], {
        map_item_variable = "MAP_ITEM"
        is_last           = i == length(local.parallel_inner_steps) - 1
        next_step         = i < length(local.parallel_inner_steps) - 1 ? local.parallel_inner_steps[i + 1].name : ""
      })
    )
  ] : []

  # Join the rendered inner steps into a single comma-separated string for
  # embedding inside the Map block's iterator definition.
  rendered_parallel_inner_steps = join(",\n      ", local.rendered_parallel_inner_list)

  # 2b. Render the Map (parallel fan-out) block itself.
  # The items_path now always points to the auto-inserted Parallel-Block-Initialization
  # step's result, which resolves the fan-out array.
  parallel_init_step_name   = local.has_parallel ? "Parallel-Block-Initialization" : ""
  parallel_init_result_path = local.has_parallel ? "${local.parallel_init_step_name}_result" : ""
  parallel_items_path       = local.has_parallel ? "$.${local.parallel_init_result_path}.Payload.source_paths" : ""

  rendered_map_block = local.has_parallel ? templatefile(
    "${path.module}/step_functions/map_block.json.tpl", {
      map_name                = local.parallel_block.name
      items_path              = local.parallel_items_path
      max_concurrency         = var.max_concurrency
      iterator_start_at       = local.parallel_inner_steps[0].name
      rendered_iterator_steps = local.rendered_parallel_inner_steps
      is_last                 = false         # chaining handled in Phase 3
      next_step               = "PLACEHOLDER" # placeholder, overridden in Phase 3
    }
  ) : ""

  # 2b-init. Render the Parallel-Block-Initialization step that runs before
  # the Map block. This Lambda resolves the fan-out array based on the
  # parallel block's input configuration.
  parallel_input_config = local.has_parallel ? local.parallel_block.input : null

  # Resolve the previous compute step before the parallel block.
  # Used as the default S3 discovery target when type=s3 and no from_step.
  parallel_previous_compute_step = local.has_parallel ? (
    length([for s in local.pre_parallel : s if contains(["batch", "lambda"], s.type)]) > 0
    ? [for s in local.pre_parallel : s.name if contains(["batch", "lambda"], s.type)][length([for s in local.pre_parallel : s if contains(["batch", "lambda"], s.type)]) - 1]
    : null
  ) : null

  # Whether the parallel block is the first thing in the pipeline (no prior
  # compute steps). Only in this case do we pass through the execution
  # payload's inputs field so the caller can provide bucket/root_prefix.
  parallel_is_first = local.has_parallel && local.parallel_previous_compute_step == null

  # Build the inputs JSON for the init Lambda payload.
  # Three cases:
  #   1. from_step is set          → static JSON with from_step details
  #   2. No from_step, has prev    → static {"type":"s3"}, Lambda uses previous_step
  #   3. No from_step, no prev     → passthrough from execution payload (is_passthrough)
  parallel_init_inputs_json = local.has_parallel ? (
    local.parallel_input_config.from_step != null
    ? (
      local.parallel_input_config.type == "s3"
      ? jsonencode({
        type        = "s3"
        from_step   = local.parallel_input_config.from_step
        root_prefix = local.parallel_input_config.root_prefix
      })
      : jsonencode({
        type      = "custom"
        from_step = local.parallel_input_config.from_step
        field     = local.parallel_input_config.field
      })
    )
    : (
      # No from_step
      local.parallel_is_first
      ? "" # passthrough — handled by is_passthrough in the template
      : jsonencode({ type = local.parallel_input_config.type })
    )
  ) : ""

  # Determine the from_step result path for the init Lambda
  # When from_step references a lambda step, we need .Payload; for batch, direct
  parallel_init_from_step_result_path = local.has_parallel && local.parallel_input_config.from_step != null ? (
    contains(
      [for s in var.steps : s.name if s.type == "lambda"],
      local.parallel_input_config.from_step
    )
    ? "${local.parallel_input_config.from_step}_result.Payload"
    : "${local.parallel_input_config.from_step}_result"
  ) : ""

  rendered_parallel_init_step = local.has_parallel ? templatefile(
    "${path.module}/step_functions/parallel_block_init_step.json.tpl", {
      step_name             = local.parallel_init_step_name
      function_name         = aws_lambda_function.pipeline_lambda["parallel_block_initialization"].function_name
      is_passthrough        = local.parallel_is_first && local.parallel_init_inputs_json == ""
      inputs_json           = local.parallel_init_inputs_json != "" ? local.parallel_init_inputs_json : ""
      intermediate_bucket   = data.aws_s3_bucket.intermediate.bucket
      source_bucket         = local.parallel_is_first ? (local.has_source_bucket ? data.aws_s3_bucket.source[0].bucket : data.aws_s3_bucket.intermediate.bucket) : ""
      from_step_result_path = local.parallel_init_from_step_result_path
      previous_step         = local.parallel_previous_compute_step != null ? local.parallel_previous_compute_step : ""
      result_path           = local.parallel_init_result_path
      next_step             = local.parallel_block.name
    }
  ) : ""

  # 2c. Render pre-parallel top-level steps.
  # These are the sequential steps that run BEFORE the parallel Map block.
  # All use "PLACEHOLDER" for Next — resolved in Phase 3.
  pre_parallel_rendered = [
    for i, step in local.pre_parallel : {
      name = step.name
      rendered = templatefile(
        "${path.module}/step_functions/${step.type}_step.json.tpl",
        merge(local.compute_step_params[step.name], {
          map_item_variable = ""
          is_last           = false
          next_step         = "PLACEHOLDER"
        })
      )
    }
  ]

  # 2d. Wrap the Parallel-Block-Initialization + Map block as entries in the
  # sequential chain. The init step is automatically inserted before the Map.
  parallel_rendered = local.has_parallel ? [
    {
      name     = local.parallel_init_step_name
      rendered = local.rendered_parallel_init_step
    },
    {
      name     = local.parallel_block.name
      rendered = local.rendered_map_block
    }
  ] : []

  # 2e. Render post-parallel top-level steps.
  # These run AFTER the parallel Map block completes.
  post_parallel_rendered = [
    for i, step in local.post_parallel : {
      name = step.name
      rendered = templatefile(
        "${path.module}/step_functions/${step.type}_step.json.tpl",
        merge(local.compute_step_params[step.name], {
          map_item_variable = ""
          is_last           = false
          next_step         = "PLACEHOLDER"
        })
      )
    }
  ]

  # Assemble the full ordered chain: pre-parallel → init + parallel → post-parallel.
  all_sequential = concat(
    local.pre_parallel_rendered,
    local.parallel_rendered,
    local.post_parallel_rendered,
  )

  # ────────────────────────────────────────────────────────────────────────────
  # Phase 3 — Chain rendered steps by replacing PLACEHOLDERs with real targets
  # ────────────────────────────────────────────────────────────────────────────

  # Determine what comes after the last sequential step:
  #   - If there's a copy step, go to Copy-To-Output first.
  #   - Otherwise, go straight to Pipeline-Completion-Notification.
  terminal_next = (
    local.has_copy_step
    ? "Copy-To-Output"
    : "Pipeline-Completion-Notification"
  )

  # Replace every "Next": "PLACEHOLDER" with the actual next state name.
  # Each step[i] points to step[i+1]; the final step points to terminal_next.
  chained_sequential = [
    for i, item in local.all_sequential : replace(
      item.rendered,
      "\"Next\": \"PLACEHOLDER\"",
      i < length(local.all_sequential) - 1
      ? "\"Next\": \"${local.all_sequential[i + 1].name}\""
      : "\"Next\": \"${local.terminal_next}\""
    )
  ]

  # Join all chained steps into a single string for injection into the
  # pipeline_definition.json.tpl template.
  rendered_sequential_section = length(local.chained_sequential) > 0 ? "${join(",\n    ", local.chained_sequential)},\n" : ""

  # ────────────────────────────────────────────────────────────────────────────
  # Optional Copy-To-Output step
  # ────────────────────────────────────────────────────────────────────────────

  # If the pipeline has a copy step, render a Batch job that copies selected
  # step outputs from the intermediate S3 bucket to the final output bucket.
  rendered_copy_list = local.has_copy_step ? [templatefile("${path.module}/step_functions/copy_to_output_step.json.tpl", {
    copy_job_definition = aws_batch_job_definition.copy_to_target[0].arn
    job_queue           = aws_batch_job_queue.pipeline.arn
    intermediate_bucket = data.aws_s3_bucket.intermediate.bucket
    output_bucket       = data.aws_s3_bucket.output[0].bucket
    steps_to_copy       = join(",", local.steps_to_copy)
  })] : []

  rendered_copy_step = join("", local.rendered_copy_list)

  # The trailing section is appended after the sequential section in the
  # pipeline definition template. Currently only the copy step lives here.
  rendered_trailing_section = local.rendered_copy_step != "" ? "${local.rendered_copy_step},\n" : ""

  # Determine the first step in the pipeline. If there are no sequential steps
  # at all, skip straight to the terminal state.
  first_sequential_step = length(local.all_sequential) > 0 ? local.all_sequential[0].name : local.terminal_next
}

# ──────────────────────────────────────────────────────────────────────────────
# Resources
# ──────────────────────────────────────────────────────────────────────────────

# CloudWatch Log Group for capturing Step Functions execution errors.
resource "aws_cloudwatch_log_group" "step_functions" {
  name              = "/aws/stepfunctions/${local.sfn_pipeline_name}"
  retention_in_days = var.cw_retention_days
  kms_key_id        = local.cloudwatch_kms_key
  tags              = local.common_tags
}

# The Step Functions state machine itself.
# Uses the pipeline_definition.json.tpl template, injecting:
#   - The rendered sequential section (all compute/parallel steps)
#   - The rendered trailing section (optional copy step)
#   - The completion SNS topic
resource "aws_sfn_state_machine" "pipeline" {
  name     = local.sfn_pipeline_name
  role_arn = aws_iam_role.step_functions.arn

  tracing_configuration {
    enabled = true
  }

  logging_configuration {
    log_destination        = "${aws_cloudwatch_log_group.step_functions.arn}:*"
    level                  = "ALL"
    include_execution_data = true
  }

  definition = templatefile("${path.module}/step_functions/pipeline_definition.json.tpl", {
    pipeline_name               = local.sfn_pipeline_name
    first_step                  = local.first_sequential_step
    rendered_sequential_section = local.rendered_sequential_section
    rendered_trailing_section   = local.rendered_trailing_section
    pipeline_completion_topic   = aws_sns_topic.pipeline_completion.arn
  })

  tags = local.common_tags
}
