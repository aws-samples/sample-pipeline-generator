"${map_name}": {
  "Type": "Map",
  "ItemsPath": "${items_path}",
  "MaxConcurrency": ${max_concurrency},
  "ItemSelector": {
    "map_item.$": "$$.Map.Item.Value",
    "state.$": "$"
  },
  "Iterator": {
    "StartAt": "${iterator_start_at}",
    "States": {
      ${rendered_iterator_steps}
    }
  },
  "ResultSelector": {
    "status": "COMPLETED"
  },
  "ResultPath": "$.${map_name}_result",
%{ if is_last ~}
  "End": true
%{ else ~}
  "Next": "${next_step}"
%{ endif ~}
}
