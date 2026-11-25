output "cluster_name" { value = module.eks.cluster_name }
output "vpc_id" { value = module.vpc.vpc_id }
output "ecr_repositories" { value = { for k, r in aws_ecr_repository.this : k => r.repository_url } }
output "db_endpoint" { value = module.rds.db_instance_address }
output "db_master_secret_arn" { value = module.rds.db_instance_master_user_secret_arn }
output "waf_acl_arn" { value = aws_wafv2_web_acl.this.arn }
output "github_deploy_role_arn" { value = aws_iam_role.github_deploy.arn }
output "github_plan_role_arn" { value = aws_iam_role.github_plan.arn }
