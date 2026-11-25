# PostgreSQL in private DB subnets. Apps authenticate with IAM tokens (no app passwords exist).
resource "aws_security_group" "db" {
  # checkov:skip=CKV2_AWS_5: Attached to the RDS instance through module.rds (vpc_security_group_ids).
  name        = "${local.name}-db"
  description = "PostgreSQL: only EKS nodes may connect"
  vpc_id      = module.vpc.vpc_id
}

resource "aws_vpc_security_group_ingress_rule" "db_from_nodes" {
  security_group_id            = aws_security_group.db.id
  referenced_security_group_id = module.eks.node_security_group_id
  ip_protocol                  = "tcp"
  from_port                    = 5432
  to_port                      = 5432
  description                  = "PostgreSQL from EKS nodes"
}

module "rds" {
  source  = "terraform-aws-modules/rds/aws"
  version = "7.2.2"

  identifier           = local.name
  engine               = "postgres"
  engine_version       = "17"
  family               = "postgres17"
  major_engine_version = "17"
  instance_class       = var.db_instance_class

  allocated_storage     = 20
  max_allocated_storage = 100 # storage autoscaling
  storage_encrypted     = true

  db_name  = "weather"
  username = "weather_admin"
  # Master password generated and rotated by AWS in Secrets Manager. Used only for one-time DB bootstrap, never by the app.
  manage_master_user_password                            = true
  iam_database_authentication_enabled                    = true
  manage_master_user_password_rotation                   = true
  master_user_password_rotation_automatically_after_days = 30

  multi_az               = var.db_multi_az
  db_subnet_group_name   = module.vpc.database_subnet_group_name
  vpc_security_group_ids = [aws_security_group.db.id]
  publicly_accessible    = false

  backup_retention_period         = 7
  deletion_protection             = var.db_deletion_protection
  skip_final_snapshot             = false
  copy_tags_to_snapshot           = true
  auto_minor_version_upgrade      = true
  enabled_cloudwatch_logs_exports = ["postgresql", "upgrade"]
  performance_insights_enabled    = true

  parameters = [
    { name = "rds.force_ssl", value = "1" }, # reject unencrypted connections
    { name = "log_connections", value = "1" },
  ]
}
