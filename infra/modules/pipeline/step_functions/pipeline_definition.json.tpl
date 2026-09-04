{
  "Comment": "Pipeline State Machine for ${pipeline_name}",
  "StartAt": "${first_step}",
  "States": {
    ${rendered_sequential_section}${rendered_trailing_section}"Pipeline-Completion-Notification": {
      "Type": "Task",
      "Resource": "arn:aws:states:::sns:publish",
      "Parameters": {
        "TopicArn": "${pipeline_completion_topic}",
        "Message": {
          "PipelineName": "${pipeline_name}",
          "ExecutionId.$": "$$.Execution.Name",
          "Status": "SUCCESS",
          "CompletedAt.$": "$$.State.EnteredTime"
        }
      },
      "Next": "End"
    },
    "End": {
      "Type": "Pass",
      "End": true,
      "Result": "Pipeline completed"
    }
  }
}
