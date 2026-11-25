# 3 AZs. Public subnets hold only the ALB and NAT; nodes and RDS live in private subnets.
module "vpc" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "6.8.0" # exact pin: module code changes only via a reviewed PR

  name = local.name
  cidr = "10.20.0.0/16"
  azs  = local.azs

  public_subnets   = ["10.20.0.0/24", "10.20.1.0/24", "10.20.2.0/24"]
  private_subnets  = ["10.20.16.0/20", "10.20.32.0/20", "10.20.48.0/20"] # large: VPC CNI gives each pod a VPC IP
  database_subnets = ["10.20.100.0/24", "10.20.101.0/24", "10.20.102.0/24"]

  enable_nat_gateway     = true
  single_nat_gateway     = var.single_nat_gateway
  one_nat_gateway_per_az = !var.single_nat_gateway

  create_database_subnet_group           = true
  create_database_internet_gateway_route = false # DB subnets have no route to the internet

  # Network forensics: who talked to what.
  enable_flow_log                                 = true
  create_flow_log_cloudwatch_log_group            = true
  create_flow_log_cloudwatch_iam_role             = true
  flow_log_cloudwatch_log_group_retention_in_days = var.log_retention_days

  # Tags the AWS Load Balancer Controller uses to find subnets.
  public_subnet_tags  = { "kubernetes.io/role/elb" = 1 }
  private_subnet_tags = { "kubernetes.io/role/internal-elb" = 1 }
}
