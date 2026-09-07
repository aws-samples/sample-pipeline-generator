"${step_name}": {
  "Type": "Task",
  "Resource": "arn:aws:states:::lambda:invoke",
  "Parameters": {
    "FunctionName": "${function_name}",
    "Payload": {
%{ if is_passthrough ~}
      "inputs.$": "$$.Execution.Input.inputs",
%{ else ~}
      "inputs": ${inputs_json},
%{ endif ~}
      "SFN_EXECUTION_ID.$": "$$.Execution.Name",
      "STEP_NAME": "${step_name}",
      "intermediate_bucket": "${intermediate_bucket}"
%{ if source_bucket != "" ~}
      ,"source_bucket": "${source_bucket}"
%{ endif ~}
%{ if from_step_result_path != "" ~}
      ,"from_step_result.$": "$.${from_step_result_path}"
%{ endif ~}
%{ if previous_step != "" ~}
      ,"previous_step": "${previous_step}"
%{ endif ~}
    }
  },
  "ResultSelector": {
    "Payload.$": "$.Payload"
  },
  "ResultPath": "$.${result_path}",
  "Next": "${next_step}"
}
