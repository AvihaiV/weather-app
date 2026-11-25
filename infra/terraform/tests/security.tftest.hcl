# Unit tests with a mocked AWS provider: no account, no credentials, no cost.
# Proves our security rules hold in the configuration. Does NOT prove AWS accepts it (that needs a real plan).
mock_provider "aws" {
  mock_data "aws_availability_zones" {
    defaults = { names = ["eu-west-1a", "eu-west-1b", "eu-west-1c"] }
  }
  mock_data "aws_caller_identity" {
    defaults = { account_id = "111122223333", arn = "arn:aws:iam::111122223333:user/test" }
  }
  mock_data "aws_iam_policy_document" {
    defaults = { json = "{\"Version\":\"2012-10-17\",\"Statement\":[]}" }
  }
  mock_data "aws_iam_session_context" {
    defaults = { issuer_arn = "arn:aws:iam::111122223333:role/admin" }
  }
  mock_data "aws_partition" {
    defaults = { partition = "aws", dns_suffix = "amazonaws.com" }
  }
  # The provider validates ARN format even against mocks, so give ARN-bearing types realistic values.
  mock_resource "aws_iam_role" {
    defaults = { arn = "arn:aws:iam::111122223333:role/mock" }
  }
  mock_resource "aws_iam_policy" {
    defaults = { arn = "arn:aws:iam::111122223333:policy/mock" }
  }
  mock_resource "aws_cloudwatch_log_group" {
    defaults = { arn = "arn:aws:logs:eu-west-1:111122223333:log-group:mock" }
  }
  mock_resource "aws_wafv2_web_acl" {
    defaults = { arn = "arn:aws:wafv2:eu-west-1:111122223333:regional/webacl/mock/0000" }
  }
  mock_resource "aws_kms_key" {
    defaults = { arn = "arn:aws:kms:eu-west-1:111122223333:key/mock" }
  }
  mock_resource "aws_eks_cluster" {
    defaults = {
      arn                   = "arn:aws:eks:eu-west-1:111122223333:cluster/mock"
      identity              = [{ oidc = [{ issuer = "https://oidc.eks.eu-west-1.amazonaws.com/id/MOCK" }] }]
      certificate_authority = [{ data = "bW9jaw==" }]
    }
  }
  mock_resource "aws_launch_template" {
    defaults = { id = "lt-0123456789abcdef0", arn = "arn:aws:ec2:eu-west-1:111122223333:launch-template/lt-0123456789abcdef0" }
  }
  mock_resource "aws_db_instance" {
    defaults = { master_user_secret = [{ secret_arn = "arn:aws:secretsmanager:eu-west-1:111122223333:secret:rds-mock" }] }
  }
  mock_data "aws_eks_addon_version" {
    defaults = { version = "v1.0.0-eksbuild.1" }
  }
  mock_resource "aws_iam_openid_connect_provider" {
    defaults = { arn = "arn:aws:iam::111122223333:oidc-provider/token.actions.githubusercontent.com" }
  }
  mock_resource "aws_ecr_repository" {
    defaults = { arn = "arn:aws:ecr:eu-west-1:111122223333:repository/mock" }
  }
}
mock_provider "tls" {
  mock_data "tls_certificate" {
    defaults = { certificates = [{ sha1_fingerprint = "9e99a48a9960b14926bb7f3b02e22da2b0ab7280" }] }
  }
}
mock_provider "time" {}
mock_provider "cloudinit" {}
mock_provider "null" {}
mock_provider "random" {}

variables {
  github_repo             = "acme/weather-app"
  state_bucket_name       = "acme-weather-tfstate"
  eks_public_access_cidrs = ["203.0.113.10/32"]
}

run "dev_security_baseline" {
  command = apply # apply against mocks = all values known, nothing real is created

  assert {
    condition     = alltrue([for r in aws_ecr_repository.this : r.image_tag_mutability == "IMMUTABLE"])
    error_message = "ECR tags must be immutable"
  }
  assert {
    condition     = alltrue([for r in aws_ecr_repository.this : r.encryption_configuration[0].encryption_type == "KMS"])
    error_message = "ECR must be KMS-encrypted"
  }
  assert {
    condition = anytrue([for s in data.aws_iam_policy_document.github_trust["deploy"].statement :
    anytrue([for c in s.condition : c.variable == "token.actions.githubusercontent.com:sub" && c.values == tolist(["repo:acme/weather-app:environment:dev"])])])
    error_message = "Deploy role must trust only this repo's protected environment"
  }
  assert {
    condition = anytrue([for s in data.aws_iam_policy_document.github_trust["plan"].statement :
    anytrue([for c in s.condition : c.variable == "token.actions.githubusercontent.com:sub" && c.values == tolist(["repo:acme/weather-app:pull_request"])])])
    error_message = "Plan role must trust only this repo's pull requests"
  }
  assert {
    condition     = alltrue([for k, p in aws_iam_role_policy.workload_db : endswith(jsondecode(p.policy).Statement[0].Resource, "/${local.workloads[k].db_user}")])
    error_message = "Each workload may connect only as its own DB user"
  }
  assert {
    condition     = alltrue([for a in aws_eks_pod_identity_association.workload : a.namespace == "weather"])
    error_message = "Workload identities must be bound to the app namespace"
  }
  assert {
    condition     = anytrue([for r in aws_wafv2_web_acl.this.rule : r.name == "rate-limit"])
    error_message = "WAF must rate-limit"
  }
  assert {
    condition     = length(aws_wafv2_web_acl.this.rule) == 4
    error_message = "WAF must have rate limit + 3 managed rule groups"
  }
}

run "prod_rejects_dev_settings" {
  command = plan
  variables { environment = "prod" } # still single NAT, single-AZ DB, 2 nodes
  expect_failures = [var.prod_guardrails]
}

run "prod_rejects_open_eks_api" {
  command = plan
  variables {
    environment             = "prod"
    single_nat_gateway      = false
    db_multi_az             = true
    node_min_size           = 3
    eks_public_access_cidrs = ["0.0.0.0/0"]
  }
  expect_failures = [var.prod_guardrails]
}

run "prod_accepts_hardened_settings" {
  command = plan
  variables {
    environment        = "prod"
    single_nat_gateway = false
    db_multi_az        = true
    node_min_size      = 3
  }
}

run "rejects_wildcard_repo" {
  command = plan
  variables { github_repo = "acme/*" }
  expect_failures = [var.github_repo]
}
