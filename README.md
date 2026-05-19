# SquishIt 🗜️

> A serverless image compression pipeline built on AWS — upload an image, get back a compressed version automatically.

![Architecture](https://img.shields.io/badge/AWS-Serverless-FF9900?style=flat&logo=amazonaws&logoColor=white)
![Python](https://img.shields.io/badge/Python-3.12-3776AB?style=flat&logo=python&logoColor=white)
![Terraform](https://img.shields.io/badge/Terraform-IaC-7B42BC?style=flat&logo=terraform&logoColor=white)
![License](https://img.shields.io/badge/License-MIT-green?style=flat)

---

## What it does

1. You upload an image through the browser (JPEG, PNG, WebP, GIF)
2. It lands in a raw S3 bucket
3. A Lambda function fires automatically, compresses the image using Pillow
4. The compressed image is saved to a second S3 bucket
5. You view and download compressed images from the gallery tab

---
<img width="1250" height="680" alt="brave_screenshot" src="https://github.com/user-attachments/assets/727de8fc-4b69-4157-a10b-1c530a7585ac" />

## Architecture

```
Browser (index.html)
    │
    ├── POST /upload-url ──→ API Gateway ──→ squishit-api Lambda
    │                                              │
    │                                    returns presigned PUT URL
    │
    ├── PUT (presigned) ──────────────→ S3 raw bucket (uploads/)
    │                                              │
    │                                    S3 event trigger
    │                                              │
    │                              squishit-compress Lambda
    │                                (Pillow compresses image)
    │                                              │
    │                              S3 compressed bucket (compressed/)
    │
    └── GET /list ────────────────────→ API Gateway ──→ squishit-api Lambda
                                                    returns presigned GET URLs
```
<img width="1254" height="438" alt="brave_screenshot_us-east-1 console aws amazon com" src="https://github.com/user-attachments/assets/2dad05a6-7a08-42e3-9eb3-3e3547d9d61b" />


### AWS Services used

| Service | Purpose |
|---|---|
| S3 (×2) | Raw uploads bucket + compressed output bucket |
| Lambda (×2) | Image compression + API handler |
| API Gateway | REST API for frontend ↔ backend |
| IAM | Least-privilege role for Lambda |
| CloudWatch | Automatic Lambda logs |

---

## Project Structure

```
squishit/
├── index.html                        # Frontend — single file, no framework
├── lambda/
│   ├── compress/
│   │   ├── lambda_function.py        # Image compression logic (Pillow)
│   │   └── requirements.txt          # Pillow dependency
│   ├── api/
│   │   └── lambda_function.py        # Presigned URL + file listing API
│   └── build.sh                      # Packages both Lambdas into zips
├── terraform/
│   ├── main.tf                       # All AWS resources
│   ├── variables.tf                  # Configurable inputs
│   ├── outputs.tf                    # Printed values after deploy
│   └── terraform.tfvars.example      # Copy → terraform.tfvars to customise
└── README.md
```

---

## Prerequisites

- [AWS CLI](https://docs.aws.amazon.com/cli/latest/userguide/install-cliv2.html) installed and configured
- [Terraform](https://developer.hashicorp.com/terraform/install) >= 1.5.0
- [Python 3](https://www.python.org/downloads/) + pip3
- An AWS account with permissions for IAM, S3, Lambda, and API Gateway

---

## Quick Start — Terraform (recommended)

The fastest way to get everything running from scratch.

```bash
# 1. Clone the repo
git clone https://github.com/your-username/squishit.git
cd squishit

# 2. Configure AWS credentials
aws configure

# 3. Deploy infrastructure
cd terraform
cp terraform.tfvars.example terraform.tfvars   # edit region/settings if needed
terraform init
terraform plan
terraform apply
```

After `terraform apply` completes, it prints your API URL. Run the output command to wire it into the frontend:

```bash
# Example — Terraform prints this for you automatically
sed -i 's|YOUR_API_GATEWAY_URL|https://xxxx.execute-api.us-east-1.amazonaws.com/prod|g' ../index.html
```

Then open `index.html` in your browser — you're live.

---

## Manual Setup (step by step)

If you prefer to set things up manually or want to understand each piece.

### Step 1 — IAM Role

```bash
chmod +x step3-iam-setup.sh
./step3-iam-setup.sh
```

Creates `squishit-lambda-role` with permissions to read/write S3 and write CloudWatch logs.

### Step 2 — S3 Buckets

```bash
chmod +x step4-s3-setup.sh
./step4-s3-setup.sh
```

Creates two buckets with public access blocked, CORS configured, and a 7-day lifecycle rule on raw uploads.

### Step 3 — Lambda Functions

```bash
chmod +x step5-lambda-deploy.sh
./step5-lambda-deploy.sh
```

Builds both Lambda packages, deploys them, and wires the S3 → compress trigger.

### Step 4 — API Gateway

```bash
chmod +x step6-api-gateway.sh
./step6-api-gateway.sh
```

Creates the REST API with `POST /upload-url` and `GET /list`, deploys to prod stage, and prints your API URL.

### Step 5 — Wire the frontend

```bash
sed -i "s|YOUR_API_GATEWAY_URL|https://YOUR_API_ID.execute-api.us-east-1.amazonaws.com/prod|g" index.html
```

---

## Configuration

| Variable | Default | Description |
|---|---|---|
| `aws_region` | `us-east-1` | AWS region to deploy into |
| `environment` | `prod` | Environment tag on all resources |
| `default_quality` | `75` | Default compression quality (10–95) |
| `raw_expiry_days` | `7` | Days before raw uploads are auto-deleted |

Override any of these in `terraform/terraform.tfvars`.

---

## API Reference

### `POST /upload-url`

Returns a presigned S3 URL for direct browser upload.

**Request body:**
```json
{
  "filename": "photo.jpg",
  "content_type": "image/jpeg",
  "quality": 75,
  "format": "same",
  "max_dimension": 1280
}
```

**Response:**
```json
{
  "upload_url": "https://s3.amazonaws.com/...",
  "key": "uploads/abc123_photo.jpg"
}
```

### `GET /list`

Returns all compressed images with presigned view/download URLs.

**Response:**
```json
[
  {
    "key": "compressed/photo_compressed.jpg",
    "url": "https://s3.amazonaws.com/...",
    "size": 204800,
    "last_modified": "2026-05-17T13:00:00",
    "original_size": 1048576,
    "savings_pct": 80.5,
    "format": "jpeg"
  }
]
```

---

## Compression Details

The compression Lambda (`squishit-compress`) supports:

| Format | Compression method |
|---|---|
| JPEG | Quality setting + progressive encoding + optimise |
| PNG | Compression level derived from quality slider |
| WebP | Quality setting + method 6 (best compression) |
| GIF | Optimise flag |

It also:
- Fixes EXIF rotation automatically (common with phone photos)
- Converts RGBA/palette images to RGB when saving as JPEG
- Resizes to a max dimension while preserving aspect ratio (optional)
- Stores savings % and original size in S3 object metadata

---

## Monitoring

Lambda logs are written to CloudWatch automatically.

```bash
# Tail compress Lambda logs
aws logs tail /aws/lambda/squishit-compress --follow

# Tail API Lambda logs
aws logs tail /aws/lambda/squishit-api --follow
```

Each compression log line looks like:
```
✓ Compressed uploads/abc_photo.jpg → compressed/photo_compressed.jpg | 2.1 MB → 420.0 KB (80.0% saved)
```

---

## Tear Down

### Terraform
```bash
cd terraform
terraform destroy
```

### Manual
```bash
# Delete Lambda functions
aws lambda delete-function --function-name squishit-compress
aws lambda delete-function --function-name squishit-api

# Empty and delete S3 buckets
aws s3 rm s3://squishit-raw-uploads-YOUR_ACCOUNT_ID --recursive
aws s3 rb s3://squishit-raw-uploads-YOUR_ACCOUNT_ID
aws s3 rm s3://squishit-compressed-YOUR_ACCOUNT_ID --recursive
aws s3 rb s3://squishit-compressed-YOUR_ACCOUNT_ID

# Delete IAM role
aws iam detach-role-policy --role-name squishit-lambda-role \
  --policy-arn arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole
aws iam delete-role-policy --role-name squishit-lambda-role --policy-name squishit-s3-access
aws iam delete-role --role-name squishit-lambda-role

# Delete API Gateway (get ID first)
aws apigateway get-rest-apis --query "items[?name=='squishit-api-gateway'].id" --output text
aws apigateway delete-rest-api --rest-api-id YOUR_API_ID
```

---

## Cost Estimate

This project runs almost entirely on the AWS free tier for low-to-moderate usage.

| Service | Free tier | Typical cost beyond free tier |
|---|---|---|
| Lambda | 1M requests/month | ~$0.20 per 1M requests |
| S3 | 5 GB storage | ~$0.023 per GB/month |
| API Gateway | 1M calls/month | ~$3.50 per 1M calls |
| CloudWatch | 5 GB logs/month | ~$0.50 per GB |

For a personal or small team project, **expect $0/month** within free tier limits.

---

## License

MIT — do whatever you want with it.
