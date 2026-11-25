variable "region" {
  type    = string
  default = "eu-west-1"
}

variable "environment" {
  type    = string
  default = "dev"
  validation {
    condition     = contains(["dev", "staging", "prod"], var.environment)
    error_message = "environment must be dev, staging or prod."
  }
}

variable "github_repo" {
  type        = string
  description = "owner/name of the GitHub repo allowed to assume the CI roles via OIDC"
  validation {
    # No wildcards: a "*" here would let any repo in the org (or GitHub) assume our roles.
    condition     = can(regex("^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$", var.github_repo))
    error_message = "github_repo must be an exact owner/name, no wildcards."
  }
}

variable "state_bucket_name" {
  type        = string
  description = "Terraform state bucket (from infra/bootstrap); the plan role needs read access"
}

variable "eks_public_access_cidrs" {
  type        = list(string)
  description = "CIDRs allowed to reach the EKS API. No default on purpose: choose consciously."
}

variable "kubernetes_version" {
  type    = string
  default = "1.34" # check `aws eks describe-cluster-versions` before apply
}

# --- Cost vs. resilience switches. Defaults = cheap dev; see prod.tfvars.example. ---
variable "single_nat_gateway" {
  type        = bool
  default     = true
  description = "true: one NAT (cheap; an AZ outage breaks egress). false: one NAT per AZ."
}

variable "db_multi_az" {
  type    = bool
  default = false
}

variable "db_instance_class" {
  type    = string
  default = "db.t4g.micro"
}

variable "db_deletion_protection" {
  type    = bool
  default = true
}

variable "node_instance_types" {
  type    = list(string)
  default = ["t3.medium"]
}

variable "node_min_size" {
  type    = number
  default = 2
}

variable "node_max_size" {
  type    = number
  default = 4
}

variable "log_retention_days" {
  type    = number
  default = 30
}

# Policy as code: prod cannot be created with the cheap, fragile dev settings.
variable "prod_guardrails" {
  type    = bool
  default = true
  validation {
    condition = !var.prod_guardrails || var.environment != "prod" || (
      var.db_multi_az && !var.single_nat_gateway && var.db_deletion_protection &&
      !contains(var.eks_public_access_cidrs, "0.0.0.0/0") && var.node_min_size >= 3
    )
    error_message = "prod requires: db_multi_az, NAT per AZ, deletion protection, no 0.0.0.0/0 on the EKS API, and >= 3 nodes."
  }
}
