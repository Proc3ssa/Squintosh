#!/usr/bin/env bash
# SquishIt — Lambda Deployment Script
# Run AFTER step4-s3-setup.sh
# Prerequisites: pip3 installed
set -euo pipefail

# ─────────────────────────────────────────────
# 0. VARIABLES — must match previous steps
# ─────────────────────────────────────────────
export AWS_REGION="us-east-1"
export AWS_ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
export RAW_BUCKET="squishit-raw-uploads-${AWS_ACCOUNT_ID}"
export COMPRESSED_BUCKET="squishit-compressed-${AWS_ACCOUNT_ID}"
export LAMBDA_ROLE_ARN="arn:aws:iam::${AWS_ACCOUNT_ID}:role/squishit-lambda-role"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
LAMBDA_DIR="$SCRIPT_DIR/lambda"
DIST_DIR="$LAMBDA_DIR/dist"

echo "Account ID  : $AWS_ACCOUNT_ID"
echo "Region      : $AWS_REGION"
echo "Role ARN    : $LAMBDA_ROLE_ARN"
echo ""


# ─────────────────────────────────────────────
# 1. BUILD THE ZIP PACKAGES
# ─────────────────────────────────────────────
echo "📦 Building Lambda packages..."
mkdir -p "$DIST_DIR"

# ── compress Lambda (needs Pillow) ────────────
echo "  Packaging compress Lambda..."
COMPRESS_TMP="$DIST_DIR/compress_tmp"
rm -rf "$COMPRESS_TMP" && mkdir -p "$COMPRESS_TMP"
cp "$LAMBDA_DIR/compress/lambda_function.py" "$COMPRESS_TMP/"

pip3 install \
  --quiet \
  --platform manylinux2014_x86_64 \
  --implementation cp \
  --python-version 3.12 \
  --only-binary=:all: \
  --target "$COMPRESS_TMP" \
  Pillow==10.3.0

cd "$COMPRESS_TMP"
zip -qr "$DIST_DIR/compress_lambda.zip" .
cd "$SCRIPT_DIR"
echo "  ✓ compress_lambda.zip ($(du -sh "$DIST_DIR/compress_lambda.zip" | cut -f1))"

# ── api Lambda (boto3 only — provided by runtime) ──
echo "  Packaging api Lambda..."
API_TMP="$DIST_DIR/api_tmp"
rm -rf "$API_TMP" && mkdir -p "$API_TMP"
cp "$LAMBDA_DIR/api/lambda_function.py" "$API_TMP/"
cd "$API_TMP"
zip -qr "$DIST_DIR/api_lambda.zip" .
cd "$SCRIPT_DIR"
echo "  ✓ api_lambda.zip ($(du -sh "$DIST_DIR/api_lambda.zip" | cut -f1))"

# Cleanup tmp dirs
rm -rf "$COMPRESS_TMP" "$API_TMP"
echo ""


# ─────────────────────────────────────────────
# 2. DEPLOY COMPRESS LAMBDA
# ─────────────────────────────────────────────
echo "🚀 Deploying squishit-compress..."

# Check if function already exists
if aws lambda get-function --function-name squishit-compress \
     --region "$AWS_REGION" &>/dev/null; then
  echo "  Function exists — updating code..."
  aws lambda update-function-code \
    --function-name squishit-compress \
    --zip-file "fileb://$DIST_DIR/compress_lambda.zip" \
    --region "$AWS_REGION" \
    --output table
else
  echo "  Creating function..."
  aws lambda create-function \
    --function-name squishit-compress \
    --runtime python3.12 \
    --role "$LAMBDA_ROLE_ARN" \
    --handler lambda_function.lambda_handler \
    --zip-file "fileb://$DIST_DIR/compress_lambda.zip" \
    --timeout 60 \
    --memory-size 512 \
    --environment "Variables={
      COMPRESSED_BUCKET=$COMPRESSED_BUCKET,
      DEFAULT_QUALITY=75,
      DEFAULT_MAX_DIM=0,
      DEFAULT_FORMAT=same
    }" \
    --region "$AWS_REGION" \
    --output table
fi

echo "  Waiting for compress function to be active..."
aws lambda wait function-active \
  --function-name squishit-compress \
  --region "$AWS_REGION"
echo "  ✓ squishit-compress is active"
echo ""


# ─────────────────────────────────────────────
# 3. DEPLOY API LAMBDA
# ─────────────────────────────────────────────
echo "🚀 Deploying squishit-api..."

if aws lambda get-function --function-name squishit-api \
     --region "$AWS_REGION" &>/dev/null; then
  echo "  Function exists — updating code..."
  aws lambda update-function-code \
    --function-name squishit-api \
    --zip-file "fileb://$DIST_DIR/api_lambda.zip" \
    --region "$AWS_REGION" \
    --output table
else
  echo "  Creating function..."
  aws lambda create-function \
    --function-name squishit-api \
    --runtime python3.12 \
    --role "$LAMBDA_ROLE_ARN" \
    --handler lambda_function.lambda_handler \
    --zip-file "fileb://$DIST_DIR/api_lambda.zip" \
    --timeout 30 \
    --memory-size 256 \
    --environment "Variables={
      RAW_BUCKET=$RAW_BUCKET,
      COMPRESSED_BUCKET=$COMPRESSED_BUCKET,
      URL_EXPIRY_SECONDS=900
    }" \
    --region "$AWS_REGION" \
    --output table
fi

echo "  Waiting for api function to be active..."
aws lambda wait function-active \
  --function-name squishit-api \
  --region "$AWS_REGION"
echo "  ✓ squishit-api is active"
echo ""


# ─────────────────────────────────────────────
# 4. WIRE S3 TRIGGER → compress Lambda
#    (fires whenever a file lands in uploads/ prefix)
# ─────────────────────────────────────────────
echo "🔗 Wiring S3 trigger on raw bucket → squishit-compress..."

# Get compress Lambda ARN
COMPRESS_ARN=$(aws lambda get-function \
  --function-name squishit-compress \
  --region "$AWS_REGION" \
  --query "Configuration.FunctionArn" \
  --output text)

# Allow S3 to invoke the compress Lambda
aws lambda add-permission \
  --function-name squishit-compress \
  --statement-id s3-trigger-permission \
  --action lambda:InvokeFunction \
  --principal s3.amazonaws.com \
  --source-arn "arn:aws:s3:::${RAW_BUCKET}" \
  --source-account "$AWS_ACCOUNT_ID" \
  --region "$AWS_REGION" 2>/dev/null || \
  echo "  (Permission already exists — skipping)"

# Add S3 event notification
cat > /tmp/s3-notification.json << EOF
{
  "LambdaFunctionConfigurations": [
    {
      "Id": "squishit-compress-trigger",
      "LambdaFunctionArn": "${COMPRESS_ARN}",
      "Events": ["s3:ObjectCreated:*"],
      "Filter": {
        "Key": {
          "FilterRules": [
            { "Name": "prefix", "Value": "uploads/" },
            { "Name": "suffix", "Value": "" }
          ]
        }
      }
    }
  ]
}
EOF

aws s3api put-bucket-notification-configuration \
  --bucket "$RAW_BUCKET" \
  --notification-configuration file:///tmp/s3-notification.json

echo "  ✓ S3 trigger wired: s3://$RAW_BUCKET/uploads/* → squishit-compress"
echo ""


# ─────────────────────────────────────────────
# 5. VERIFY
# ─────────────────────────────────────────────
echo "=== Deployed Lambda Functions ==="
aws lambda list-functions \
  --region "$AWS_REGION" \
  --query "Functions[?starts_with(FunctionName,'squishit')].[FunctionName,Runtime,MemorySize,Timeout,LastModified]" \
  --output table

echo ""
echo "✅ Lambda deployment complete!"
echo ""
echo "Save these for the next step (API Gateway):"
echo "  COMPRESS_ARN = $COMPRESS_ARN"
API_ARN=$(aws lambda get-function \
  --function-name squishit-api \
  --region "$AWS_REGION" \
  --query "Configuration.FunctionArn" \
  --output text)
echo "  API_ARN      = $API_ARN"
echo "  AWS_REGION   = $AWS_REGION"
echo "  AWS_ACCOUNT_ID = $AWS_ACCOUNT_ID"
