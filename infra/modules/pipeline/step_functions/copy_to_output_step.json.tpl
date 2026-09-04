"Copy-To-Output": {
  "Type": "Task",
  "Resource": "arn:aws:states:::batch:submitJob.sync",
  "Parameters": {
    "JobDefinition": "${copy_job_definition}",
    "JobName.$": "$$.Execution.Name",
    "JobQueue": "${job_queue}",
    "ContainerOverrides": {
      "Environment": [
        { "Name": "SFN_EXECUTION_ID", "Value.$": "$$.Execution.Name" },
        { "Name": "INTERMEDIATE_BUCKET", "Value": "${intermediate_bucket}" },
        { "Name": "OUTPUT_BUCKET", "Value": "${output_bucket}" },
        { "Name": "SOURCE_STEP_NAMES", "Value": "${steps_to_copy}" }
      ]
    }
  },
  "ResultPath": null,
  "Next": "Pipeline-Completion-Notification"
}
