output "api_url" {
  description = "Base URL of the API Gateway"
  value       = aws_api_gateway_deployment.prod.invoke_url
}

output "upload_url_endpoint" {
  description = "POST endpoint to get a presigned upload URL"
  value       = "${aws_api_gateway_deployment.prod.invoke_url}/upload-url"
}

output "list_endpoint" {
  description = "GET endpoint to list compressed images"
  value       = "${aws_api_gateway_deployment.prod.invoke_url}/list"
}

output "raw_bucket_name" {
  description = "S3 bucket that receives raw uploads"
  value       = aws_s3_bucket.raw.bucket
}

output "compressed_bucket_name" {
  description = "S3 bucket that stores compressed images"
  value       = aws_s3_bucket.compressed.bucket
}

output "compress_lambda_arn" {
  description = "ARN of the compression Lambda function"
  value       = aws_lambda_function.compress.arn
}

output "api_lambda_arn" {
  description = "ARN of the API Lambda function"
  value       = aws_lambda_function.api.arn
}

output "frontend_config" {
  description = "One-liner to wire the API URL into index.html"
  value       = "sed -i 's|YOUR_API_GATEWAY_URL|${aws_api_gateway_deployment.prod.invoke_url}|g' ../index.html"
}
