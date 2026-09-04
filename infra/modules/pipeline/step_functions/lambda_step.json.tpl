"${step_name}": {
  "Type": "Task",
  "Resource": "arn:aws:states:::lambda:invoke",
  "Parameters": {
    "FunctionName": "${function_arn}",
    "Payload": {
      "SFN_EXECUTION_ID.$": "$$.Execution.Name"
      ,"EXECUTION_INPUT.$": "$$.Execution.Input"
%{ if map_item_variable != "" ~}
      ,"${map_item_variable}.$": "$.map_item"
%{ for key, value in previous_steps ~}
      ,"${key}.$": "$.state.${value}"
%{ endfor ~}
%{ else ~}
%{ for key, value in previous_steps ~}
      ,"${key}.$": "$.${value}"
%{ endfor ~}
%{ endif ~}
    }
  },
  "ResultSelector": {
    "Payload.$": "$.Payload"
  },
  ${result_path_json},
%{ if is_last ~}
  "End": true
%{ else ~}
  "Next": "${next_step}"
%{ endif ~}
}
