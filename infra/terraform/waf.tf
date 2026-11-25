# WAF in front of the public ALB. The Ingress references this ACL by ARN (annotation in the Helm chart).
resource "aws_wafv2_web_acl" "this" {
  # checkov:skip=CKV_AWS_192: Log4j protection IS present (AWSManagedRulesKnownBadInputsRuleSet); Checkov cannot see inside the dynamic block.
  name  = local.name
  scope = "REGIONAL"

  default_action {
    allow {}
  }

  # Per-IP rate limit: blunts scraping and simple floods. 1000 requests per 5 minutes is far above normal use.
  rule {
    name     = "rate-limit"
    priority = 0
    action {
      block {}
    }
    statement {
      rate_based_statement {
        limit              = 1000
        aggregate_key_type = "IP"
      }
    }
    visibility_config {
      cloudwatch_metrics_enabled = true
      metric_name                = "rate-limit"
      sampled_requests_enabled   = true
    }
  }

  dynamic "rule" {
    for_each = {
      AWSManagedRulesAmazonIpReputationList = 1 # known bad IPs / botnets
      AWSManagedRulesCommonRuleSet          = 2 # OWASP-style common attacks
      AWSManagedRulesKnownBadInputsRuleSet  = 3 # e.g. Log4Shell patterns
    }
    content {
      name     = rule.key
      priority = rule.value
      override_action {
        none {}
      }
      statement {
        managed_rule_group_statement {
          vendor_name = "AWS"
          name        = rule.key
        }
      }
      visibility_config {
        cloudwatch_metrics_enabled = true
        metric_name                = rule.key
        sampled_requests_enabled   = true
      }
    }
  }

  visibility_config {
    cloudwatch_metrics_enabled = true
    metric_name                = local.name
    sampled_requests_enabled   = true
  }
}

resource "aws_cloudwatch_log_group" "waf" {
  # checkov:skip=CKV_AWS_158: Encrypted at rest by default with an AWS-owned key. Customer-managed KMS is a listed next step.
  # checkov:skip=CKV_AWS_338: Retention is var.log_retention_days (30 dev / 365 prod).
  name              = "aws-waf-logs-${local.name}" # WAF requires the "aws-waf-logs-" prefix
  retention_in_days = var.log_retention_days
}

resource "aws_wafv2_web_acl_logging_configuration" "this" {
  resource_arn            = aws_wafv2_web_acl.this.arn
  log_destination_configs = [aws_cloudwatch_log_group.waf.arn]
}
