#!/usr/bin/env bash
# SquishIt — S3 Bucket Setup
# Run AFTER step3-iam-setup.sh
set -euo pipefail

# ─────────────────────────────────────────────
# 0. VARIABLES — must match step 3 values
# ─────────────────────────────────────────────
export AWS_REGION="us-east-1"
export AWS_ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
export RAW_BUCKET="squishit-raw-uploads-${AWS_ACCOUNT_ID}"
export COMPRESSED_BUCKET="squishit-compressed-${AWS_ACCOUNT_ID}"

echo "Account ID        : $AWS_ACCOUNT_ID"
echo "Region            : $AWS_REGION"
echo "Raw bucket        : $RAW_BUCKET"
echo "Compressed bucket : $COMPRESSED_BUCKET"
echo ""


# ─────────────────────────────────────────────
# 1. CREATE THE TWO BUCKETS
# ─────────────────────────────────────────────

# us-east-1 does NOT use LocationConstraint (AWS quirk)
echo "Creating raw uploads bucket..."
aws s3api create-bucket \
  --bucket "$RAW_BUCKET" \
  --region "$AWS_REGION"

echo "Creating compressed bucket..."
aws s3api create-bucket \
  --bucket "$COMPRESSED_BUCKET" \
  --region "$AWS_REGION"

echo "✓ Buckets created"


# ─────────────────────────────────────────────
# 2. BLOCK ALL PUBLIC ACCESS ON BOTH BUCKETS
#    (images served via presigned URLs only)
# ─────────────────────────────────────────────
for BUCKET in "$RAW_BUCKET" "$COMPRESSED_BUCKET"; do
  aws s3api put-public-access-block \
    --bucket "$BUCKET" \
    --public-access-block-configuration \
      "BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true"
  echo "✓ Public access blocked on $BUCKET"
done


# ─────────────────────────────────────────────
# 3. ENABLE VERSIONING ON COMPRESSED BUCKET
#    (optional but good practice)
# ─────────────────────────────────────────────
aws s3api put-bucket-versioning \
  --bucket "$COMPRESSED_BUCKET" \
  --versioning-configuration Status=Enabled

echo "✓ Versioning enabled on $COMPRESSED_BUCKET"


# ─────────────────────────────────────────────
# 4. CORS ON RAW BUCKET
#    (browser needs to PUT directly to S3 via presigned URL)
# ─────────────────────────────────────────────
cat > /tmp/raw-cors.json << 'EOF'
{
  "CORSRules": [
    {
      "AllowedOrigins": ["*"],
      "AllowedMethods": ["PUT", "GET", "HEAD"],
      "AllowedHeaders": ["*"],
      "ExposeHeaders": ["ETag"],
      "MaxAgeSeconds": 3000
    }
  ]
}
EOF

aws s3api put-bucket-cors \
  --bucket "$RAW_BUCKET" \
  --cors-configuration file:///tmp/raw-cors.json

echo "✓ CORS configured on raw bucket"


# ─────────────────────────────────────────────
# 5. CORS ON COMPRESSED BUCKET
#    (browser needs to GET images via presigned URL)
# ─────────────────────────────────────────────
cat > /tmp/compressed-cors.json << 'EOF'
{
  "CORSRules": [
    {
      "AllowedOrigins": ["*"],
      "AllowedMethods": ["GET", "HEAD"],
      "AllowedHeaders": ["*"],
      "ExposeHeaders": ["Content-Length", "Content-Type"],
      "MaxAgeSeconds": 3000
    }
  ]
}
EOF

aws s3api put-bucket-cors \
  --bucket "$COMPRESSED_BUCKET" \
  --cors-configuration file:///tmp/compressed-cors.json

echo "✓ CORS configured on compressed bucket"


# ─────────────────────────────────────────────
# 6. LIFECYCLE RULE ON RAW BUCKET
#    (auto-delete raw uploads after 7 days to save cost)
# ─────────────────────────────────────────────
cat > /tmp/raw-lifecycle.json << 'EOF'
{
  "Rules": [
    {
      "ID": "expire-raw-uploads",
      "Status": "Enabled",
      "Filter": { "Prefix": "uploads/" },
      "Expiration": { "Days": 7 }
    }
  ]
}
EOF

aws s3api put-bucket-lifecycle-configuration \
  --bucket "$RAW_BUCKET" \
  --lifecycle-configuration file:///tmp/raw-lifecycle.json

echo "✓ Lifecycle rule set: raw uploads auto-delete after 7 days"


# ─────────────────────────────────────────────
# 7. VERIFY
# ─────────────────────────────────────────────
echo ""
echo "=== Bucket List ==="
aws s3api list-buckets \
  --query "Buckets[?contains(Name,'squishit')].Name" \
  --output table

echo ""
echo "✅ S3 setup complete!"
echo ""
echo "Save these for the next steps:"
echo "  RAW_BUCKET        = $RAW_BUCKET"
echo "  COMPRESSED_BUCKET = $COMPRESSED_BUCKET"
echo "  AWS_REGION        = $AWS_REGION"
echo "  AWS_ACCOUNT_ID    = $AWS_ACCOUNT_ID"
