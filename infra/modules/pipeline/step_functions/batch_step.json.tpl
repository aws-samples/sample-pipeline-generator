"${step_name}": {
  "Type": "Task",
  "Resource": "arn:aws:states:::batch:submitJob.sync",
  "Parameters": {
    "JobDefinition": "${job_definition}",
    "JobName.$": "$$.Execution.Name",
    "JobQueue": "${job_queue}",
    "ContainerOverrides": {
      "Environment": [
        { "Name": "SFN_EXECUTION_ID", "Value.$": "$$.Execution.Name" }
        ,{ "Name": "EXECUTION_INPUT", "Value.$": "States.JsonToString($$.Execution.Input)" }
%{ if map_item_variable != "" ~}
        ,{ "Name": "${map_item_variable}", "Value.$": "States.JsonToString($.map_item)" }
%{ for key, value in previous_steps ~}
        ,{ "Name": "${key}", "Value.$": "States.JsonToString($.state.${value})" }
%{ endfor ~}
%{ else ~}
%{ for key, value in previous_steps ~}
        ,{ "Name": "${key}", "Value.$": "States.JsonToString($.${value})" }
%{ endfor ~}
%{ endif ~}
      ]
    }
  },
  "ResultSelector": {
    "status.$": "$.Status",
    "job_id.$": "$.JobId",
    "exit_code.$": "$.Container.ExitCode"
  },
  ${result_path_json},
%{ if is_last ~}
  "End": true
%{ else ~}
  "Next": "${next_step}"
%{ endif ~}
}
