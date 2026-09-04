<!-- Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved. SPDX-License-Identifier: MIT-0 -->

# Lambda CloudWatch alarms module

This module creates CloudWatch alarms for Lambda functions following AWS best practices.

## Alarms created

- **Errors**: Detects high error counts (Sum > threshold)
- **Throttles**: Detects throttled invocations (Sum >= 1)
- **Duration**: Detects long execution times (p90 > threshold)
- **ConcurrentExecutions**: Detects high concurrency usage (Max > 90% quota)

## Usage

```hcl
module "lambda_alarms" {
  source = "../../modules/lambda-alarms"

  lambda_functions = {
    my_function = {
      function_name           = "my-lambda-function"
      error_threshold         = 5
      duration_threshold_ms   = 10000
      concurrent_exec_percent = 0.9
    }
  }

  account_concurrency_quota = 1000
  tags = {
    Environment = "dev"
  }
}
```

<!-- BEGIN_TF_DOCS -->


## Requirements

| Name | Version |
|------|---------|
| <a name="requirement_terraform"></a> [terraform](#requirement\_terraform) | >= 1.8 |
| <a name="requirement_aws"></a> [aws](#requirement\_aws) | ~> 6.0 |

## Providers

| Name | Version |
|------|---------|
| <a name="provider_aws"></a> [aws](#provider\_aws) | ~> 6.0 |

## Modules

No modules.

## Resources

| Name | Type |
|------|------|
| aws_cloudwatch_metric_alarm.lambda_concurrent_executions | resource |
| aws_cloudwatch_metric_alarm.lambda_duration | resource |
| aws_cloudwatch_metric_alarm.lambda_errors | resource |
| aws_cloudwatch_metric_alarm.lambda_throttles | resource |

## Inputs

| Name | Description | Type | Default | Required |
|------|-------------|------|---------|:--------:|
| <a name="input_account_concurrency_quota"></a> [account\_concurrency\_quota](#input\_account\_concurrency\_quota) | AWS account Lambda concurrency quota for the region | `number` | `1000` | no |
| <a name="input_lambda_functions"></a> [lambda\_functions](#input\_lambda\_functions) | Map of Lambda function names to their configurations | <pre>map(object({<br/>    function_name           = string<br/>    error_threshold         = optional(number, 1)<br/>    duration_threshold_ms   = optional(number, 5000)<br/>    concurrent_exec_percent = optional(number, 0.9)<br/>  }))</pre> | n/a | yes |
| <a name="input_tags"></a> [tags](#input\_tags) | Tags to apply to all alarms | `map(string)` | `{}` | no |

## Outputs

| Name | Description |
|------|-------------|
| <a name="output_concurrent_execution_alarm_arns"></a> [concurrent\_execution\_alarm\_arns](#output\_concurrent\_execution\_alarm\_arns) | ARNs of concurrent execution alarms |
| <a name="output_duration_alarm_arns"></a> [duration\_alarm\_arns](#output\_duration\_alarm\_arns) | ARNs of duration alarms |
| <a name="output_error_alarm_arns"></a> [error\_alarm\_arns](#output\_error\_alarm\_arns) | ARNs of error alarms |
| <a name="output_throttle_alarm_arns"></a> [throttle\_alarm\_arns](#output\_throttle\_alarm\_arns) | ARNs of throttle alarms |
<!-- END_TF_DOCS -->
