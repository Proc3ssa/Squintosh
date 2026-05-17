variable "aws_region" {
  description = "AWS region to deploy into"
  type        = string
  default     = "us-east-1"
}

variable "environment" {
  description = "Deployment environment tag"
  type        = string
  default     = "prod"
}

variable "default_quality" {
  description = "Default JPEG/WebP compression quality (10-95)"
  type        = number
  default     = 75
}

variable "raw_expiry_days" {
  description = "Days before raw uploads are auto-deleted"
  type        = number
  default     = 7
}
