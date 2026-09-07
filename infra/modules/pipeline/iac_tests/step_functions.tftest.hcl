# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: MIT-0

variables {
  vpc_id                 = "vpc-0123456789abcdef0"
  subnet_ids             = ["subnet-0123456789abcdef0", "subnet-0123456789abcdef1"]
  ecr_force_delete       = true
  lambda_steps_code_path = "/tmp/lambda-steps"
}

provider "aws" {
  region = "us-east-1"
}

run "setup" {
  module {
    source = "./iac_tests/setup"
  }
}

# ─────────────────────────────────────────────────────────────────────────────
# 1. Single lambda step — no previous steps, only discovered sources
# ─────────────────────────────────────────────────────────────────────────────
run "test_single_lambda_no_previous_steps" {
  command = plan

  override_data {
    target = data.archive_file.lambda_step_zip
    values = {
      output_base64sha256 = "dGVzdA=="
    }
  }

  variables {
    steps = [
      {
        name               = "my-lambda"
        type               = "lambda"
        lambda_timeout     = 300
        lambda_memory_size = 1024
      }
    ]

    initialization = {
      pipeline_name = "test-single-lambda"
      environment   = "dev"
      region        = "us-east-1"
      tags          = {}
      buckets = {
        names   = { intermediate = run.setup.bucket }
        kms_key = run.setup.aws_s3_kms
      }
    }
  }

  assert {
    condition     = length(local.compute_step_params["my-lambda"].previous_steps) == 0
    error_message = "First step should have no previous_steps"
  }

  assert {
    condition     = local.first_sequential_step == "my-lambda"
    error_message = "First sequential step should be my-lambda"
  }

  assert {
    condition     = length(local.all_sequential) == 1
    error_message = "Should have exactly 1 sequential step"
  }
}

# ─────────────────────────────────────────────────────────────────────────────
# 2. Single batch step — no previous steps
# ─────────────────────────────────────────────────────────────────────────────
run "test_single_batch_no_previous_steps" {
  command = plan

  variables {
    steps = [
      {
        name = "my-batch"
        type = "batch"
      }
    ]

    initialization = {
      pipeline_name = "test-single-batch"
      environment   = "dev"
      region        = "us-east-1"
      tags          = {}
      buckets = {
        names   = { intermediate = run.setup.bucket }
        kms_key = run.setup.aws_s3_kms
      }
    }
  }

  assert {
    condition     = length(local.compute_step_params["my-batch"].previous_steps) == 0
    error_message = "First step should have no previous_steps"
  }
}

# ─────────────────────────────────────────────────────────────────────────────
# 3. Lambda → Batch: batch auto-receives STEP_LAMBDA_STEP with Payload
# ─────────────────────────────────────────────────────────────────────────────
run "test_batch_auto_receives_previous_lambda" {
  command = plan

  override_data {
    target = data.archive_file.lambda_step_zip
    values = {
      output_base64sha256 = "dGVzdA=="
    }
  }

  variables {
    steps = [
      {
        name               = "pre-process"
        type               = "lambda"
        lambda_timeout     = 300
        lambda_memory_size = 1024
      },
      {
        name = "aggregate"
        type = "batch"
      }
    ]

    initialization = {
      pipeline_name = "test-auto-lambda-to-batch"
      environment   = "dev"
      region        = "us-east-1"
      tags          = {}
      buckets = {
        names   = { intermediate = run.setup.bucket }
        kms_key = run.setup.aws_s3_kms
      }
    }
  }

  # Lambda source → auto Payload
  assert {
    condition     = local.compute_step_params["aggregate"].previous_steps["STEP_PRE_PROCESS"] == "pre-process_result.Payload"
    error_message = "Batch should auto-receive STEP_PRE_PROCESS = pre-process_result.Payload"
  }

  assert {
    condition     = length(local.compute_step_params["aggregate"].previous_steps) == 1
    error_message = "Batch should have exactly 1 previous step"
  }

  assert {
    condition     = local.all_sequential[*].name == ["pre-process", "aggregate"]
    error_message = "Sequential chain should be [pre-process, aggregate]"
  }
}

# ─────────────────────────────────────────────────────────────────────────────
# 4. Batch → Batch: second batch auto-receives STEP_INGEST without Payload
# ─────────────────────────────────────────────────────────────────────────────
run "test_batch_auto_receives_previous_batch" {
  command = plan

  variables {
    steps = [
      {
        name = "ingest"
        type = "batch"
      },
      {
        name = "transform"
        type = "batch"
      }
    ]

    initialization = {
      pipeline_name = "test-auto-batch-to-batch"
      environment   = "dev"
      region        = "us-east-1"
      tags          = {}
      buckets = {
        names   = { intermediate = run.setup.bucket }
        kms_key = run.setup.aws_s3_kms
      }
    }
  }

  # Batch source → no Payload
  assert {
    condition     = local.compute_step_params["transform"].previous_steps["STEP_INGEST"] == "ingest_result"
    error_message = "Batch should auto-receive STEP_INGEST = ingest_result (no Payload)"
  }

  assert {
    condition     = local.all_sequential[*].name == ["ingest", "transform"]
    error_message = "Sequential chain should be [ingest, transform]"
  }
}


# ─────────────────────────────────────────────────────────────────────────────
# 5. Three sequential steps: third step sees both previous steps
# ─────────────────────────────────────────────────────────────────────────────
run "test_multiple_previous_steps_accumulated" {
  command = plan

  override_data {
    target = data.archive_file.lambda_step_zip
    values = {
      output_base64sha256 = "dGVzdA=="
    }
  }

  variables {
    steps = [
      {
        name = "step-a"
        type = "batch"
      },
      {
        name               = "step-b"
        type               = "lambda"
        lambda_timeout     = 60
        lambda_memory_size = 512
      },
      {
        name = "step-c"
        type = "batch"
      }
    ]

    initialization = {
      pipeline_name = "test-accumulated"
      environment   = "dev"
      region        = "us-east-1"
      tags          = {}
      buckets = {
        names   = { intermediate = run.setup.bucket }
        kms_key = run.setup.aws_s3_kms
      }
    }
  }

  assert {
    condition     = length(local.compute_step_params["step-c"].previous_steps) == 2
    error_message = "Third step should see 2 previous steps"
  }

  assert {
    condition     = local.compute_step_params["step-c"].previous_steps["STEP_STEP_A"] == "step-a_result"
    error_message = "Third step should see batch step-a without Payload"
  }

  assert {
    condition     = local.compute_step_params["step-c"].previous_steps["STEP_STEP_B"] == "step-b_result.Payload"
    error_message = "Third step should see lambda step-b with Payload"
  }

  assert {
    condition     = length(local.compute_step_params["step-b"].previous_steps) == 1
    error_message = "Second step should see 1 previous step"
  }

  assert {
    condition     = length(local.compute_step_params["step-a"].previous_steps) == 0
    error_message = "First step should see 0 previous steps"
  }
}

# ─────────────────────────────────────────────────────────────────────────────
# 6. Parallel inner lambda sees all pre-parallel steps
#    Now includes auto-inserted Parallel-Block-Initialization step
# ─────────────────────────────────────────────────────────────────────────────
run "test_parallel_inner_sees_pre_parallel_steps" {
  command = plan

  override_data {
    target = data.archive_file.lambda_step_zip
    values = {
      output_base64sha256 = "dGVzdA=="
    }
  }

  variables {
    steps = [
      {
        name               = "splitter"
        type               = "lambda"
        lambda_timeout     = 300
        lambda_memory_size = 1024
      },
      {
        name = "fan-out"
        type = "parallel"
        input = {
          type      = "custom"
          from_step = "splitter"
          field     = "chunks"
        }
        parallel_steps = [
          {
            name               = "process-one"
            type               = "lambda"
            lambda_timeout     = 300
            lambda_memory_size = 1024
          }
        ]
      }
    ]

    initialization = {
      pipeline_name = "test-parallel-inner"
      environment   = "dev"
      region        = "us-east-1"
      tags          = {}
      buckets = {
        names   = { intermediate = run.setup.bucket }
        kms_key = run.setup.aws_s3_kms
      }
    }
  }

  assert {
    condition     = length(local.compute_step_params["process-one"].previous_steps) == 1
    error_message = "Parallel inner step should see 1 pre-parallel step"
  }

  assert {
    condition     = local.compute_step_params["process-one"].previous_steps["STEP_SPLITTER"] == "splitter_result.Payload"
    error_message = "Parallel inner step should see splitter with Payload"
  }

  # Sequential chain now includes the auto-inserted init step
  assert {
    condition     = local.all_sequential[*].name == ["splitter", "Parallel-Block-Initialization", "fan-out"]
    error_message = "Sequential chain should be [splitter, Parallel-Block-Initialization, fan-out]"
  }
}

# ─────────────────────────────────────────────────────────────────────────────
# 7. Post-parallel batch sees pre-parallel + parallel block
# ─────────────────────────────────────────────────────────────────────────────
run "test_post_parallel_sees_all_previous" {
  command = plan

  override_data {
    target = data.archive_file.lambda_step_zip
    values = {
      output_base64sha256 = "dGVzdA=="
    }
  }

  variables {
    steps = [
      {
        name               = "ingest"
        type               = "lambda"
        lambda_timeout     = 300
        lambda_memory_size = 1024
      },
      {
        name = "process"
        type = "parallel"
        input = {
          type      = "custom"
          from_step = "ingest"
          field     = "chunks"
        }
        parallel_steps = [
          {
            name               = "transform"
            type               = "lambda"
            lambda_timeout     = 300
            lambda_memory_size = 1024
          }
        ]
      },
      {
        name = "aggregate"
        type = "batch"
      }
    ]

    initialization = {
      pipeline_name = "test-post-parallel"
      environment   = "dev"
      region        = "us-east-1"
      tags          = {}
      buckets = {
        names   = { intermediate = run.setup.bucket }
        kms_key = run.setup.aws_s3_kms
      }
    }
  }

  # Post-parallel batch sees lambda (with Payload) + parallel block (no Payload)
  assert {
    condition     = length(local.compute_step_params["aggregate"].previous_steps) == 2
    error_message = "Post-parallel step should see 2 previous steps (lambda + parallel)"
  }

  assert {
    condition     = local.compute_step_params["aggregate"].previous_steps["STEP_INGEST"] == "ingest_result.Payload"
    error_message = "Post-parallel should see ingest with Payload (lambda source)"
  }

  assert {
    condition     = local.compute_step_params["aggregate"].previous_steps["STEP_PROCESS"] == "process_result"
    error_message = "Post-parallel should see process without Payload (parallel block)"
  }

  # Sequential chain includes the auto-inserted init step
  assert {
    condition     = local.all_sequential[*].name == ["ingest", "Parallel-Block-Initialization", "process", "aggregate"]
    error_message = "Sequential chain should be [ingest, Parallel-Block-Initialization, process, aggregate]"
  }
}


# ─────────────────────────────────────────────────────────────────────────────
# 9. Env var naming: hyphens → underscores, uppercased
# ─────────────────────────────────────────────────────────────────────────────
run "test_env_var_naming_convention" {
  command = plan

  override_data {
    target = data.archive_file.lambda_step_zip
    values = {
      output_base64sha256 = "dGVzdA=="
    }
  }

  variables {
    steps = [
      {
        name               = "my-fancy-step"
        type               = "lambda"
        lambda_timeout     = 60
        lambda_memory_size = 512
      },
      {
        name = "consumer"
        type = "batch"
      }
    ]

    initialization = {
      pipeline_name = "test-naming"
      environment   = "dev"
      region        = "us-east-1"
      tags          = {}
      buckets = {
        names   = { intermediate = run.setup.bucket }
        kms_key = run.setup.aws_s3_kms
      }
    }
  }

  assert {
    condition     = contains(keys(local.compute_step_params["consumer"].previous_steps), "STEP_MY_FANCY_STEP")
    error_message = "Env var should be STEP_MY_FANCY_STEP (hyphens → underscores, uppercased)"
  }
}

# ─────────────────────────────────────────────────────────────────────────────
# 10. Complex pipeline — mirrors the complex-test deployment
#     batch → lambda → lambda → parallel(batch, lambda) → batch → lambda
#     Exercises: all step types, runtime_parameters, parallel fan-out,
#     copy_to_target, accumulated previous_steps
# ─────────────────────────────────────────────────────────────────────────────
run "test_complex_pipeline" {
  command = plan

  override_data {
    target = data.archive_file.lambda_step_zip
    values = {
      output_base64sha256 = "dGVzdA=="
    }
  }

  variables {
    steps = [
      {
        name   = "ingest-raw-data"
        type   = "batch"
        ram_mb = 4096
        vcpu   = 2
        runtime_parameters = {
          SOURCE_SYSTEM  = "source_system"
          INGESTION_MODE = "ingestion_mode"
        }
      },
      {
        name               = "validate-ingestion"
        type               = "lambda"
        lambda_timeout     = 300
        lambda_memory_size = 1024
        runtime_parameters = {
          VALIDATION_PROFILE = "validation_profile"
        }
      },
      {
        name               = "split-workload"
        type               = "lambda"
        lambda_timeout     = 600
        lambda_memory_size = 2048
      },
      {
        name = "fan-out-processing"
        type = "parallel"
        input = {
          type      = "custom"
          from_step = "split-workload"
          field     = "chunks"
        }
        parallel_steps = [
          {
            name   = "transform-chunk"
            type   = "batch"
            ram_mb = 8192
            vcpu   = 4
            runtime_parameters = {
              TRANSFORM_CONFIG = "transform_config"
            }
          },
          {
            name               = "score-chunk"
            type               = "lambda"
            lambda_timeout     = 900
            lambda_memory_size = 3008
          }
        ]
      },
      {
        name           = "aggregate-results"
        type           = "batch"
        ram_mb         = 4096
        vcpu           = 2
        copy_to_target = true
      },
      {
        name               = "publish-report"
        type               = "lambda"
        lambda_timeout     = 120
        lambda_memory_size = 512
        runtime_parameters = {
          REPORT_FORMAT     = "report_format"
          DISTRIBUTION_LIST = "distribution_list"
        }
      }
    ]

    initialization = {
      pipeline_name = "complex-test"
      environment   = "dev"
      region        = "us-east-1"
      tags          = {}
      buckets = {
        names = {
          source       = run.setup.bucket
          intermediate = run.setup.bucket
          output       = run.setup.bucket
        }
        kms_key = run.setup.aws_s3_kms
      }
    }

    copy_to_target_ecr_url = "123456789012.dkr.ecr.us-east-1.amazonaws.com/copy-to-output"
  }

  # ── Sequential chain ordering (now includes auto-inserted init step) ──
  assert {
    condition = local.all_sequential[*].name == [
      "ingest-raw-data", "validate-ingestion",
      "split-workload", "Parallel-Block-Initialization", "fan-out-processing",
      "aggregate-results", "publish-report"
    ]
    error_message = "Full sequential chain should match expected order"
  }

  assert {
    condition     = local.first_sequential_step == "ingest-raw-data"
    error_message = "First sequential step should be ingest-raw-data"
  }

  # ── Pre-parallel / post-parallel split ──
  assert {
    condition     = length(local.pre_parallel) == 3
    error_message = "Should have 3 pre-parallel steps (batch, lambda, lambda)"
  }

  assert {
    condition     = length(local.post_parallel) == 2
    error_message = "Should have 2 post-parallel steps (batch, lambda)"
  }

  assert {
    condition     = [for s in local.pre_parallel : s.name] == ["ingest-raw-data", "validate-ingestion", "split-workload"]
    error_message = "Pre-parallel steps should be in correct order"
  }

  assert {
    condition     = [for s in local.post_parallel : s.name] == ["aggregate-results", "publish-report"]
    error_message = "Post-parallel steps should be in correct order"
  }

  # ── Parallel block configuration ──
  assert {
    condition     = local.has_parallel == true
    error_message = "Pipeline should have a parallel block"
  }

  assert {
    condition     = local.parallel_block.name == "fan-out-processing"
    error_message = "Parallel block should be fan-out-processing"
  }

  assert {
    condition     = local.parallel_block.input.from_step == "split-workload"
    error_message = "Parallel block should fan out from split-workload"
  }

  assert {
    condition     = local.parallel_items_path == "$.Parallel-Block-Initialization_result.Payload.source_paths"
    error_message = "Parallel items path should reference the init step result"
  }

  assert {
    condition     = length(local.parallel_inner_steps) == 2
    error_message = "Parallel block should have 2 inner steps"
  }

  assert {
    condition     = [for s in local.parallel_inner_steps : s.name] == ["transform-chunk", "score-chunk"]
    error_message = "Parallel inner steps should be [transform-chunk, score-chunk]"
  }

  # ── First step: no previous steps ──
  assert {
    condition     = length(local.compute_step_params["ingest-raw-data"].previous_steps) == 0
    error_message = "ingest-raw-data (first step) should have no previous steps"
  }

  # ── Second step: sees first batch step ──
  assert {
    condition     = length(local.compute_step_params["validate-ingestion"].previous_steps) == 1
    error_message = "validate-ingestion should see 1 previous step"
  }

  assert {
    condition     = local.compute_step_params["validate-ingestion"].previous_steps["STEP_INGEST_RAW_DATA"] == "ingest-raw-data_result"
    error_message = "validate-ingestion should see batch ingest-raw-data without Payload"
  }

  # ── split-workload: sees ingest-raw-data + validate-ingestion ──
  assert {
    condition     = length(local.compute_step_params["split-workload"].previous_steps) == 2
    error_message = "split-workload should see 2 previous compute steps"
  }

  assert {
    condition     = local.compute_step_params["split-workload"].previous_steps["STEP_INGEST_RAW_DATA"] == "ingest-raw-data_result"
    error_message = "split-workload should see ingest-raw-data without Payload"
  }

  assert {
    condition     = local.compute_step_params["split-workload"].previous_steps["STEP_VALIDATE_INGESTION"] == "validate-ingestion_result.Payload"
    error_message = "split-workload should see validate-ingestion with Payload"
  }

  # ── Parallel inner steps: see all pre-parallel compute steps ──
  assert {
    condition     = length(local.compute_step_params["transform-chunk"].previous_steps) == 3
    error_message = "transform-chunk (parallel inner) should see 3 pre-parallel compute steps"
  }

  assert {
    condition     = local.compute_step_params["transform-chunk"].previous_steps["STEP_INGEST_RAW_DATA"] == "ingest-raw-data_result"
    error_message = "transform-chunk should see ingest-raw-data without Payload"
  }

  assert {
    condition     = local.compute_step_params["transform-chunk"].previous_steps["STEP_VALIDATE_INGESTION"] == "validate-ingestion_result.Payload"
    error_message = "transform-chunk should see validate-ingestion with Payload"
  }

  assert {
    condition     = local.compute_step_params["transform-chunk"].previous_steps["STEP_SPLIT_WORKLOAD"] == "split-workload_result.Payload"
    error_message = "transform-chunk should see split-workload with Payload"
  }

  # score-chunk (second parallel inner) sees same pre-parallel steps
  assert {
    condition     = length(local.compute_step_params["score-chunk"].previous_steps) == 3
    error_message = "score-chunk (parallel inner) should see 3 pre-parallel compute steps"
  }

  # ── Post-parallel: aggregate-results sees all top-level steps before it ──
  assert {
    condition     = length(local.compute_step_params["aggregate-results"].previous_steps) == 4
    error_message = "aggregate-results should see 4 previous top-level steps"
  }

  assert {
    condition     = local.compute_step_params["aggregate-results"].previous_steps["STEP_INGEST_RAW_DATA"] == "ingest-raw-data_result"
    error_message = "aggregate-results should see ingest-raw-data without Payload"
  }

  assert {
    condition     = local.compute_step_params["aggregate-results"].previous_steps["STEP_VALIDATE_INGESTION"] == "validate-ingestion_result.Payload"
    error_message = "aggregate-results should see validate-ingestion with Payload"
  }

  assert {
    condition     = local.compute_step_params["aggregate-results"].previous_steps["STEP_SPLIT_WORKLOAD"] == "split-workload_result.Payload"
    error_message = "aggregate-results should see split-workload with Payload"
  }

  assert {
    condition     = local.compute_step_params["aggregate-results"].previous_steps["STEP_FAN_OUT_PROCESSING"] == "fan-out-processing_result"
    error_message = "aggregate-results should see fan-out-processing without Payload (parallel block)"
  }

  # ── Final step: publish-report sees all 5 preceding top-level compute/parallel steps ──
  assert {
    condition     = length(local.compute_step_params["publish-report"].previous_steps) == 5
    error_message = "publish-report should see 5 previous top-level steps"
  }

  assert {
    condition     = local.compute_step_params["publish-report"].previous_steps["STEP_AGGREGATE_RESULTS"] == "aggregate-results_result"
    error_message = "publish-report should see aggregate-results without Payload"
  }

  # ── Runtime parameters forwarded correctly ──
  assert {
    condition     = local.compute_step_params["ingest-raw-data"].runtime_parameters["SOURCE_SYSTEM"] == "source_system"
    error_message = "ingest-raw-data should have SOURCE_SYSTEM runtime parameter"
  }

  assert {
    condition     = length(local.compute_step_params["ingest-raw-data"].runtime_parameters) == 2
    error_message = "ingest-raw-data should have exactly 2 runtime parameters"
  }

  assert {
    condition     = local.compute_step_params["transform-chunk"].runtime_parameters["TRANSFORM_CONFIG"] == "transform_config"
    error_message = "transform-chunk (parallel inner) should have TRANSFORM_CONFIG runtime parameter"
  }

  assert {
    condition     = length(local.compute_step_params["publish-report"].runtime_parameters) == 2
    error_message = "publish-report should have exactly 2 runtime parameters"
  }

  assert {
    condition     = length(local.compute_step_params["split-workload"].runtime_parameters) == 0
    error_message = "split-workload should have no runtime parameters"
  }

  # ── Copy-to-target triggers trailing section ──
  assert {
    condition     = local.has_copy_step == true
    error_message = "Pipeline should have a copy step (aggregate-results has copy_to_target=true)"
  }

  assert {
    condition     = local.terminal_next == "Copy-To-Output"
    error_message = "Terminal next should be Copy-To-Output when copy_to_target is enabled"
  }

  # ── ResultPath fragments ──
  assert {
    condition     = local.result_path_fragment["ingest-raw-data"] == "\"ResultPath\": \"$.ingest-raw-data_result\""
    error_message = "ResultPath for ingest-raw-data should be correct"
  }

  assert {
    condition     = local.result_path_fragment["score-chunk"] == "\"ResultPath\": \"$.score-chunk_result\""
    error_message = "ResultPath for score-chunk (parallel inner) should be correct"
  }
}
