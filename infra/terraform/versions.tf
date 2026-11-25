terraform {
  required_version = ">= 1.10"
  required_providers {
    aws = { source = "hashicorp/aws", version = "~> 6.74" }
  }
  # Partial config: bucket/key/region come from `-backend-config=backend.hcl` (see backend.hcl.example).
  # use_lockfile = S3-native state locking, no DynamoDB table needed (Terraform >= 1.10).
  backend "s3" {
    encrypt      = true
    use_lockfile = true
  }
}

provider "aws" {
  region = var.region
  default_tags {
    tags = { Project = "weather", Environment = var.environment, ManagedBy = "terraform" }
  }
}

data "aws_caller_identity" "current" {}
data "aws_availability_zones" "available" { state = "available" }

locals {
  name       = "weather-${var.environment}"
  azs        = slice(data.aws_availability_zones.available.names, 0, 3)
  account_id = data.aws_caller_identity.current.account_id
  namespace  = "weather" # the only K8s namespace CI may deploy to
}
