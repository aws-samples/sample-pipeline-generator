<!-- Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved. SPDX-License-Identifier: MIT-0 -->

# Pipeline account bootstrap module

Bootstraps a pipeline account with optional VPC endpoints for private connectivity to AWS services.

## What's inside

- **VPC Endpoints** (optional): Gateway and interface endpoints for S3, ECR, DynamoDB, Step Functions, CloudWatch, SSM, and Secrets Manager

## Required tags

The `tags` input is mandatory and **must contain a non-empty `Owner` key**. The tags are applied to all module-managed resources.

## Usage

Deploy this module **once per pipeline account** before deploying pipelines:

```hcl
module "bootstrap" {
  source = "../modules/pipeline-account-bootstrap"

  region = "us-east-1"

  # VPC Endpoints (optional)
  vpc_id              = "vpc-0123456789abcdef0"
  vpc_subnet_ids      = ["subnet-aaa", "subnet-bbb"]
  vpc_route_table_ids = ["rtb-aaa", "rtb-bbb"]
  vpc_endpoints       = ["s3", "ecr", "dynamodb", "stepfunctions"]

  tags = {
    Owner       = "workflow-platform"     # required
    Environment = "dev"
  }
}
```

## When to use

- First-time setup of a pipeline account
- Provisioning VPC endpoints for private connectivity to AWS services

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
| aws_security_group.vpc_endpoints | resource |
| aws_vpc_endpoint.gateway | resource |
| aws_vpc_endpoint.interface | resource |
| aws_vpc.selected | data source |

## Inputs

| Name | Description | Type | Default | Required |
|------|-------------|------|---------|:--------:|
| <a name="input_region"></a> [region](#input\_region) | AWS Region for VPC endpoint service names | `string` | n/a | yes |
| <a name="input_tags"></a> [tags](#input\_tags) | Tags applied to module resources. Must include a non-empty 'Owner' key. | `map(string)` | n/a | yes |
| <a name="input_vpc_endpoints"></a> [vpc\_endpoints](#input\_vpc\_endpoints) | List of endpoint types to create. Supported values: s3, ecr, dynamodb, stepfunctions, cloudwatch, ssm, secretsmanager | `list(string)` | `[]` | no |
| <a name="input_vpc_id"></a> [vpc\_id](#input\_vpc\_id) | ID of the VPC where endpoints will be created. Required when vpc\_endpoints is non-empty. | `string` | `null` | no |
| <a name="input_vpc_route_table_ids"></a> [vpc\_route\_table\_ids](#input\_vpc\_route\_table\_ids) | List of route table IDs for gateway VPC endpoints (S3, DynamoDB) | `list(string)` | `[]` | no |
| <a name="input_vpc_subnet_ids"></a> [vpc\_subnet\_ids](#input\_vpc\_subnet\_ids) | List of subnet IDs for interface VPC endpoints | `list(string)` | `[]` | no |

## Outputs

| Name | Description |
|------|-------------|
| <a name="output_gateway_endpoint_ids"></a> [gateway\_endpoint\_ids](#output\_gateway\_endpoint\_ids) | Map of gateway VPC endpoint names to their IDs |
| <a name="output_interface_endpoint_ids"></a> [interface\_endpoint\_ids](#output\_interface\_endpoint\_ids) | Map of interface VPC endpoint names to their IDs |
| <a name="output_vpc_endpoints_security_group_id"></a> [vpc\_endpoints\_security\_group\_id](#output\_vpc\_endpoints\_security\_group\_id) | ID of the security group used by interface VPC endpoints |
<!-- END_TF_DOCS -->
