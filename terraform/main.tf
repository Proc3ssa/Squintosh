terraform {
  required_version = ">= 1.5.0"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}

provider "aws" {
  region = var.aws_region
}

# ─────────────────────────────────────────────
# DATA
# ─────────────────────────────────────────────
data "aws_caller_identity" "current" {}

locals {
  account_id        = data.aws_caller_identity.current.account_id
  raw_bucket_name   = "squishit-raw-uploads-${local.account_id}"
  comp_bucket_name  = "squishit-compressed-${local.account_id}"
}


# ─────────────────────────────────────────────
# S3 — RAW UPLOADS BUCKET
# ─────────────────────────────────────────────
resource "aws_s3_bucket" "raw" {
  bucket        = local.raw_bucket_name
  force_destroy = true

  tags = {
    Project     = "squishit"
    Environment = var.environment
  }
}

resource "aws_s3_bucket_public_access_block" "raw" {
  bucket                  = aws_s3_bucket.raw.id
  block_public_acls       = true
  ignore_public_acls      = true
  block_public_policy     = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_cors_configuration" "raw" {
  bucket = aws_s3_bucket.raw.id

  cors_rule {
    allowed_origins = ["*"]
    allowed_methods = ["PUT", "GET", "HEAD"]
    allowed_headers = ["*"]
    expose_headers  = ["ETag"]
    max_age_seconds = 3000
  }
}

resource "aws_s3_bucket_lifecycle_configuration" "raw" {
  bucket = aws_s3_bucket.raw.id

  rule {
    id     = "expire-raw-uploads"
    status = "Enabled"

    filter {
      prefix = "uploads/"
    }

    expiration {
      days = var.raw_expiry_days
    }
  }
}

# S3 trigger → compress Lambda
resource "aws_s3_bucket_notification" "raw_trigger" {
  bucket = aws_s3_bucket.raw.id

  lambda_function {
    lambda_function_arn = aws_lambda_function.compress.arn
    events              = ["s3:ObjectCreated:*"]
    filter_prefix       = "uploads/"
  }

  depends_on = [aws_lambda_permission.allow_s3]
}


# ─────────────────────────────────────────────
# S3 — COMPRESSED BUCKET
# ─────────────────────────────────────────────
resource "aws_s3_bucket" "compressed" {
  bucket        = local.comp_bucket_name
  force_destroy = true

  tags = {
    Project     = "squishit"
    Environment = var.environment
  }
}

resource "aws_s3_bucket_public_access_block" "compressed" {
  bucket                  = aws_s3_bucket.compressed.id
  block_public_acls       = true
  ignore_public_acls      = true
  block_public_policy     = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_versioning" "compressed" {
  bucket = aws_s3_bucket.compressed.id
  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_cors_configuration" "compressed" {
  bucket = aws_s3_bucket.compressed.id

  cors_rule {
    allowed_origins = ["*"]
    allowed_methods = ["GET", "HEAD"]
    allowed_headers = ["*"]
    expose_headers  = ["Content-Length", "Content-Type"]
    max_age_seconds = 3000
  }
}


# ─────────────────────────────────────────────
# IAM ROLE
# ─────────────────────────────────────────────
resource "aws_iam_role" "lambda_role" {
  name        = "squishit-lambda-role"
  description = "SquishIt Lambda execution role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "lambda.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })

  tags = {
    Project = "squishit"
  }
}

resource "aws_iam_role_policy_attachment" "lambda_basic" {
  role       = aws_iam_role.lambda_role.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

resource "aws_iam_role_policy" "s3_access" {
  name = "squishit-s3-access"
  role = aws_iam_role.lambda_role.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "ReadRawBucket"
        Effect = "Allow"
        Action = ["s3:GetObject", "s3:HeadObject"]
        Resource = "${aws_s3_bucket.raw.arn}/*"
      },
      {
        Sid    = "PresignedURLsForRawBucket"
        Effect = "Allow"
        Action = ["s3:PutObject", "s3:GetObject"]
        Resource = "${aws_s3_bucket.raw.arn}/*"
      },
      {
        Sid    = "WriteCompressedBucket"
        Effect = "Allow"
        Action = ["s3:PutObject", "s3:GetObject", "s3:HeadObject", "s3:ListBucket"]
        Resource = [
          aws_s3_bucket.compressed.arn,
          "${aws_s3_bucket.compressed.arn}/*"
        ]
      }
    ]
  })
}


# ─────────────────────────────────────────────
# LAMBDA — BUILD PACKAGES
# ─────────────────────────────────────────────
resource "null_resource" "build_lambdas" {
  triggers = {
    compress_src = filemd5("${path.module}/../lambda/compress/lambda_function.py")
    api_src      = filemd5("${path.module}/../lambda/api/lambda_function.py")
  }

  provisioner "local-exec" {
    command     = "bash build.sh"
    working_dir = "${path.module}/../lambda"
  }
}


# ─────────────────────────────────────────────
# LAMBDA — COMPRESS FUNCTION
# ─────────────────────────────────────────────
resource "aws_lambda_function" "compress" {
  function_name    = "squishit-compress"
  role             = aws_iam_role.lambda_role.arn
  handler          = "lambda_function.lambda_handler"
  runtime          = "python3.12"
  filename         = "${path.module}/../lambda/dist/compress_lambda.zip"
  source_code_hash = filebase64sha256("${path.module}/../lambda/dist/compress_lambda.zip")
  timeout          = 60
  memory_size      = 512

  environment {
    variables = {
      COMPRESSED_BUCKET = aws_s3_bucket.compressed.bucket
      DEFAULT_QUALITY   = tostring(var.default_quality)
      DEFAULT_MAX_DIM   = "0"
      DEFAULT_FORMAT    = "same"
    }
  }

  depends_on = [null_resource.build_lambdas]

  tags = {
    Project     = "squishit"
    Environment = var.environment
  }
}

resource "aws_lambda_permission" "allow_s3" {
  statement_id   = "s3-trigger-permission"
  action         = "lambda:InvokeFunction"
  function_name  = aws_lambda_function.compress.function_name
  principal      = "s3.amazonaws.com"
  source_arn     = aws_s3_bucket.raw.arn
  source_account = local.account_id
}


# ─────────────────────────────────────────────
# LAMBDA — API FUNCTION
# ─────────────────────────────────────────────
resource "aws_lambda_function" "api" {
  function_name    = "squishit-api"
  role             = aws_iam_role.lambda_role.arn
  handler          = "lambda_function.lambda_handler"
  runtime          = "python3.12"
  filename         = "${path.module}/../lambda/dist/api_lambda.zip"
  source_code_hash = filebase64sha256("${path.module}/../lambda/dist/api_lambda.zip")
  timeout          = 30
  memory_size      = 256

  environment {
    variables = {
      RAW_BUCKET        = aws_s3_bucket.raw.bucket
      COMPRESSED_BUCKET = aws_s3_bucket.compressed.bucket
      URL_EXPIRY_SECONDS = "900"
    }
  }

  depends_on = [null_resource.build_lambdas]

  tags = {
    Project     = "squishit"
    Environment = var.environment
  }
}

resource "aws_lambda_permission" "allow_apigw" {
  statement_id  = "apigateway-invoke"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.api.function_name
  principal     = "apigateway.amazonaws.com"
  source_arn    = "${aws_api_gateway_rest_api.api.execution_arn}/*/*"
}


# ─────────────────────────────────────────────
# API GATEWAY
# ─────────────────────────────────────────────
resource "aws_api_gateway_rest_api" "api" {
  name        = "squishit-api-gateway"
  description = "SquishIt image compressor API"

  tags = {
    Project     = "squishit"
    Environment = var.environment
  }
}

# ── /upload-url ──────────────────────────────
resource "aws_api_gateway_resource" "upload_url" {
  rest_api_id = aws_api_gateway_rest_api.api.id
  parent_id   = aws_api_gateway_rest_api.api.root_resource_id
  path_part   = "upload-url"
}

resource "aws_api_gateway_method" "upload_url_post" {
  rest_api_id   = aws_api_gateway_rest_api.api.id
  resource_id   = aws_api_gateway_resource.upload_url.id
  http_method   = "POST"
  authorization = "NONE"
}

resource "aws_api_gateway_integration" "upload_url_post" {
  rest_api_id             = aws_api_gateway_rest_api.api.id
  resource_id             = aws_api_gateway_resource.upload_url.id
  http_method             = aws_api_gateway_method.upload_url_post.http_method
  integration_http_method = "POST"
  type                    = "AWS_PROXY"
  uri                     = aws_lambda_function.api.invoke_arn
}

resource "aws_api_gateway_method" "upload_url_options" {
  rest_api_id   = aws_api_gateway_rest_api.api.id
  resource_id   = aws_api_gateway_resource.upload_url.id
  http_method   = "OPTIONS"
  authorization = "NONE"
}

resource "aws_api_gateway_integration" "upload_url_options" {
  rest_api_id = aws_api_gateway_rest_api.api.id
  resource_id = aws_api_gateway_resource.upload_url.id
  http_method = aws_api_gateway_method.upload_url_options.http_method
  type        = "MOCK"
  request_templates = {
    "application/json" = "{\"statusCode\":200}"
  }
}

resource "aws_api_gateway_method_response" "upload_url_options_200" {
  rest_api_id = aws_api_gateway_rest_api.api.id
  resource_id = aws_api_gateway_resource.upload_url.id
  http_method = aws_api_gateway_method.upload_url_options.http_method
  status_code = "200"
  response_parameters = {
    "method.response.header.Access-Control-Allow-Headers" = false
    "method.response.header.Access-Control-Allow-Methods" = false
    "method.response.header.Access-Control-Allow-Origin"  = false
  }
}

resource "aws_api_gateway_integration_response" "upload_url_options" {
  rest_api_id = aws_api_gateway_rest_api.api.id
  resource_id = aws_api_gateway_resource.upload_url.id
  http_method = aws_api_gateway_method.upload_url_options.http_method
  status_code = "200"
  response_parameters = {
    "method.response.header.Access-Control-Allow-Headers" = "'Content-Type,X-Amz-Date,Authorization,X-Api-Key'"
    "method.response.header.Access-Control-Allow-Methods" = "'POST,OPTIONS'"
    "method.response.header.Access-Control-Allow-Origin"  = "'*'"
  }
  depends_on = [aws_api_gateway_integration.upload_url_options]
}

# ── /list ────────────────────────────────────
resource "aws_api_gateway_resource" "list" {
  rest_api_id = aws_api_gateway_rest_api.api.id
  parent_id   = aws_api_gateway_rest_api.api.root_resource_id
  path_part   = "list"
}

resource "aws_api_gateway_method" "list_get" {
  rest_api_id   = aws_api_gateway_rest_api.api.id
  resource_id   = aws_api_gateway_resource.list.id
  http_method   = "GET"
  authorization = "NONE"
}

resource "aws_api_gateway_integration" "list_get" {
  rest_api_id             = aws_api_gateway_rest_api.api.id
  resource_id             = aws_api_gateway_resource.list.id
  http_method             = aws_api_gateway_method.list_get.http_method
  integration_http_method = "POST"
  type                    = "AWS_PROXY"
  uri                     = aws_lambda_function.api.invoke_arn
}

resource "aws_api_gateway_method" "list_options" {
  rest_api_id   = aws_api_gateway_rest_api.api.id
  resource_id   = aws_api_gateway_resource.list.id
  http_method   = "OPTIONS"
  authorization = "NONE"
}

resource "aws_api_gateway_integration" "list_options" {
  rest_api_id = aws_api_gateway_rest_api.api.id
  resource_id = aws_api_gateway_resource.list.id
  http_method = aws_api_gateway_method.list_options.http_method
  type        = "MOCK"
  request_templates = {
    "application/json" = "{\"statusCode\":200}"
  }
}

resource "aws_api_gateway_method_response" "list_options_200" {
  rest_api_id = aws_api_gateway_rest_api.api.id
  resource_id = aws_api_gateway_resource.list.id
  http_method = aws_api_gateway_method.list_options.http_method
  status_code = "200"
  response_parameters = {
    "method.response.header.Access-Control-Allow-Headers" = false
    "method.response.header.Access-Control-Allow-Methods" = false
    "method.response.header.Access-Control-Allow-Origin"  = false
  }
}

resource "aws_api_gateway_integration_response" "list_options" {
  rest_api_id = aws_api_gateway_rest_api.api.id
  resource_id = aws_api_gateway_resource.list.id
  http_method = aws_api_gateway_method.list_options.http_method
  status_code = "200"
  response_parameters = {
    "method.response.header.Access-Control-Allow-Headers" = "'Content-Type,X-Amz-Date,Authorization,X-Api-Key'"
    "method.response.header.Access-Control-Allow-Methods" = "'GET,OPTIONS'"
    "method.response.header.Access-Control-Allow-Origin"  = "'*'"
  }
  depends_on = [aws_api_gateway_integration.list_options]
}

# ── Deployment ───────────────────────────────
resource "aws_api_gateway_deployment" "prod" {
  rest_api_id = aws_api_gateway_rest_api.api.id
  stage_name  = "prod"

  triggers = {
    redeployment = sha1(jsonencode([
      aws_api_gateway_resource.upload_url.id,
      aws_api_gateway_method.upload_url_post.id,
      aws_api_gateway_integration.upload_url_post.id,
      aws_api_gateway_resource.list.id,
      aws_api_gateway_method.list_get.id,
      aws_api_gateway_integration.list_get.id,
    ]))
  }

  lifecycle {
    create_before_destroy = true
  }

  depends_on = [
    aws_api_gateway_integration.upload_url_post,
    aws_api_gateway_integration.list_get,
  ]
}
