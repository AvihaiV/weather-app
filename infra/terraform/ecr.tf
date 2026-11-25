resource "aws_kms_key" "ecr" {
  # checkov:skip=CKV2_AWS_64: Default key policy (account root administers, IAM policies grant use) is the intended model.
  description         = "ECR image encryption"
  enable_key_rotation = true
}

resource "aws_ecr_repository" "this" {
  for_each = toset(["backend", "frontend"])

  name                 = "weather/${each.key}"
  image_tag_mutability = "IMMUTABLE" # a tag can never be re-pointed to different code
  encryption_configuration {
    encryption_type = "KMS"
    kms_key         = aws_kms_key.ecr.arn
  }
  image_scanning_configuration { scan_on_push = true }
}

resource "aws_ecr_lifecycle_policy" "this" {
  for_each   = aws_ecr_repository.this
  repository = each.value.name
  policy = jsonencode({
    rules = [{
      rulePriority = 1
      description  = "Keep the last 30 images"
      selection    = { tagStatus = "any", countType = "imageCountMoreThan", countNumber = 30 }
      action       = { type = "expire" }
    }]
  })
}
