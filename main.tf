data "aws_caller_identity" "current" {}
data "aws_partition" "current" {}
data "aws_region" "current" {}

module "label_sns_topic" {
  source     = "cloudposse/label/null"
  version    = "0.22.1"
  attributes = concat(module.this.attributes, ["sns-topic"])
  context    = module.this.context
  tags       = merge(module.this.tags, var.sns_topic_tags)
}

module "label_lambda" {
  source     = "cloudposse/label/null"
  version    = "0.22.1"
  attributes = concat(module.this.attributes, ["lambda"])
  context    = module.this.context
  tags       = merge(module.this.tags, var.lambda_function_tags)
}

module "label_lambda_role" {
  source     = "cloudposse/label/null"
  version    = "0.22.1"
  attributes = concat(module.label_lambda.attributes, ["role"])
  context    = module.this.context
  tags       = merge(module.label_lambda.tags, var.iam_role_tags)
}

resource "aws_sns_topic" "this" {
  count = var.create_sns_topic && module.this.enabled ? 1 : 0

  name = module.label_sns_topic.id

  kms_master_key_id = var.sns_topic_kms_key_id

  tags = module.label_sns_topic.tags
}

locals {
  sns_topic_arn = element(
    concat(
      aws_sns_topic.this.*.arn,
      ["arn:${data.aws_partition.current.id}:sns:${data.aws_region.current.name}:${data.aws_caller_identity.current.account_id}:${var.sns_topic_name}"],
      [""]
    ),
    0,
  )

  lambda_policy_document = {
    sid       = "AllowWriteToCloudwatchLogs"
    effect    = "Allow"
    actions   = ["logs:CreateLogStream", "logs:PutLogEvents"]
    resources = [replace("${element(concat(aws_cloudwatch_log_group.lambda[*].arn, [""]), 0)}:*", ":*:*", ":*")]
  }

  lambda_policy_document_kms = {
    sid       = "AllowKMSDecrypt"
    effect    = "Allow"
    actions   = ["kms:Decrypt"]
    resources = [var.kms_key_arn]
  }
}

data "aws_iam_policy_document" "lambda" {
  count = module.this.enabled ? 1 : 0

  dynamic "statement" {
    for_each = concat([local.lambda_policy_document], var.kms_key_arn != "" ? [local.lambda_policy_document_kms] : [])
    content {
      sid       = statement.value.sid
      effect    = statement.value.effect
      actions   = statement.value.actions
      resources = statement.value.resources
    }
  }
}

resource "aws_cloudwatch_log_group" "lambda" {
  count = module.this.enabled ? 1 : 0

  name              = "/aws/lambda/${module.label_lambda.id}"
  retention_in_days = var.cloudwatch_log_group_retention_in_days
  kms_key_id        = var.cloudwatch_log_group_kms_key_id

  tags = merge(module.this.tags, var.cloudwatch_log_group_tags)
}

resource "aws_sns_topic_subscription" "sns_notify_slack" {
  count = module.this.enabled ? 1 : 0

  topic_arn     = local.sns_topic_arn
  protocol      = "lambda"
  endpoint      = module.lambda.lambda_function_arn
  filter_policy = var.subscription_filter_policy
}

module "lambda" {
  source  = "terraform-aws-modules/lambda/aws"
  version = "2.17.0"

  create = module.this.enabled

  function_name = module.label_lambda.id
  description   = var.lambda_description

  handler                        = "notify_pushbullet.lambda_handler"
  source_path                    = "${path.module}/functions/notify_pushbullet.py"
  runtime                        = "python3.8"
  timeout                        = 30
  kms_key_arn                    = var.kms_key_arn
  reserved_concurrent_executions = var.reserved_concurrent_executions

  # If publish is disabled, there will be "Error adding new Lambda Permission for notify_slack: InvalidParameterValueException: We currently do not support adding policies for $LATEST."
  publish = true

  environment_variables = {
    PUSHBULLET_API_KEYS = jsonencode(var.pushbullet_api_keys)
    LOG_EVENTS          = var.log_events ? "True" : "False"
  }

  create_role               = var.lambda_role == ""
  lambda_role               = var.lambda_role
  role_name                 = module.label_lambda_role.id
  role_permissions_boundary = var.iam_role_boundary_policy_arn
  role_tags                 = module.label_lambda_role.tags

  # Do not use Lambda's policy for cloudwatch logs, because we have to add a policy
  # for KMS conditionally. This way attach_policy_json is always true independenty of
  # the value of presense of KMS. Famous "computed values in count" bug...
  attach_cloudwatch_logs_policy = false
  attach_policy_json            = true
  policy_json                   = element(concat(data.aws_iam_policy_document.lambda[*].json, [""]), 0)

  use_existing_cloudwatch_log_group = true
  attach_network_policy             = var.lambda_function_vpc_subnet_ids != null

  allowed_triggers = {
    AllowExecutionFromSNS = {
      principal  = "sns.amazonaws.com"
      source_arn = local.sns_topic_arn
    }
  }

  store_on_s3 = var.lambda_function_store_on_s3
  s3_bucket   = var.lambda_function_s3_bucket

  vpc_subnet_ids         = var.lambda_function_vpc_subnet_ids
  vpc_security_group_ids = var.lambda_function_vpc_security_group_ids

  tags = module.label_lambda.tags

  depends_on = [aws_cloudwatch_log_group.lambda]
}
