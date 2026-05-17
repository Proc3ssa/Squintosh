# SquishIt — Terraform variable overrides
# Copy this file to terraform.tfvars and edit as needed

aws_region      = "us-east-1"   # change to your preferred region
environment     = "prod"
default_quality = 75            # compression quality 10-95
raw_expiry_days = 7             # days before raw uploads are deleted
