# One-time bootstrap: the S3 bucket that holds Terraform state for infra/terraform.
# Chicken-and-egg: this root uses local state. Run once by an admin, then never again.
terraform {
  required_version = ">= 1.10"
  required_providers {
    aws = { source = "hashicorp/aws", version = "~> 6.74" }
  }
}

provider "aws" {
  region = var.region
}

variable "region" {
  type    = string
  default = "eu-west-1"
}

variable "state_bucket_name" {
  type        = string
  description = "Globally unique bucket name, e.g. <org>-weather-tfstate"
}

resource "aws_kms_key" "state" {
  # checkov:skip=CKV2_AWS_64: Default key policy (account root administers, IAM policies grant use) is the intended model.
  description         = "Terraform state encryption"
  enable_key_rotation = true
}

resource "aws_s3_bucket" "state" {
  # checkov:skip=CKV_AWS_144: Cross-region replication: doubles cost; versioning covers accidental deletes. Next step for prod.
  # checkov:skip=CKV_AWS_18: Access logging needs a separate log bucket; CloudTrail data events are the planned audit path.
  # checkov:skip=CKV2_AWS_62: Event notifications have no consumer for a state bucket.
  bucket = var.state_bucket_name
  lifecycle { prevent_destroy = true }
}

# Versioning = recover from a corrupted or accidentally deleted state file.
resource "aws_s3_bucket_versioning" "state" {
  bucket = aws_s3_bucket.state.id
  versioning_configuration { status = "Enabled" }
}

# Old state versions kept 90 days for recovery, then deleted (cost + less sensitive data lying around).
resource "aws_s3_bucket_lifecycle_configuration" "state" {
  bucket = aws_s3_bucket.state.id
  rule {
    id     = "expire-old-versions"
    status = "Enabled"
    filter {}
    noncurrent_version_expiration { noncurrent_days = 90 }
    abort_incomplete_multipart_upload { days_after_initiation = 7 }
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "state" {
  bucket = aws_s3_bucket.state.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm     = "aws:kms"
      kms_master_key_id = aws_kms_key.state.arn
    }
    bucket_key_enabled = true
  }
}

resource "aws_s3_bucket_public_access_block" "state" {
  bucket                  = aws_s3_bucket.state.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_ownership_controls" "state" {
  bucket = aws_s3_bucket.state.id
  rule { object_ownership = "BucketOwnerEnforced" }
}

# State can contain sensitive values: refuse any non-TLS access.
resource "aws_s3_bucket_policy" "state" {
  bucket = aws_s3_bucket.state.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid       = "DenyInsecureTransport"
      Effect    = "Deny"
      Principal = "*"
      Action    = "s3:*"
      Resource  = [aws_s3_bucket.state.arn, "${aws_s3_bucket.state.arn}/*"]
      Condition = { Bool = { "aws:SecureTransport" = "false" } }
    }]
  })
}

output "state_bucket" { value = aws_s3_bucket.state.id }
output "state_kms_key_arn" { value = aws_kms_key.state.arn }
