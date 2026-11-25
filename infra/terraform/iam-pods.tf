# One IAM role per workload (Pod Identity). Each may only log in to the DB as its own least-privilege user.
locals {
  workloads = {
    backend   = { service_account = "weather-backend", db_user = "weather_api" }         # SELECT only
    collector = { service_account = "weather-collector", db_user = "weather_collector" } # INSERT/DELETE
    migrate   = { service_account = "weather-migrate", db_user = "weather_migrate" }     # owns the schema
  }
}

data "aws_iam_policy_document" "pod_trust" {
  statement {
    actions = ["sts:AssumeRole", "sts:TagSession"]
    principals {
      type        = "Service"
      identifiers = ["pods.eks.amazonaws.com"]
    }
    condition {
      test     = "StringEquals"
      variable = "aws:SourceAccount"
      values   = [local.account_id]
    }
  }
}

resource "aws_iam_role" "workload" {
  for_each           = local.workloads
  name               = "${local.name}-${each.key}"
  assume_role_policy = data.aws_iam_policy_document.pod_trust.json
}

resource "aws_iam_role_policy" "workload_db" {
  for_each = local.workloads
  name     = "rds-connect"
  role     = aws_iam_role.workload[each.key].id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = "rds-db:connect"
      Resource = "arn:aws:rds-db:${var.region}:${local.account_id}:dbuser:${module.rds.db_instance_resource_id}/${each.value.db_user}"
    }]
  })
}

resource "aws_eks_pod_identity_association" "workload" {
  for_each        = local.workloads
  cluster_name    = module.eks.cluster_name
  namespace       = local.namespace
  service_account = each.value.service_account
  role_arn        = aws_iam_role.workload[each.key].arn
}
